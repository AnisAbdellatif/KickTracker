defmodule KickTracker.DeadLetters do
  @moduledoc """
  The dead-letter queue (project.md §8.3, §13.8): messages the consumer
  rejected (undecodable, a bad signature) or that failed ten deliveries.
  The admin lists and inspects them, replays one into `kick.events`, or
  discards it with a reason (recorded in the audit log). Nothing leaves
  the queue silently.

  Talks to RabbitMQ as the `ops` user (`DEAD_LETTERS_AMQP_URL`): read on
  the dead-letter queue, write on the exchange, nothing else. Listing
  takes messages without acknowledging them and puts them all back.

  The queue is a quorum queue, where putting messages back lands a moment
  later; every call waits (up to 2s) until they are back before it
  returns, so a count, a list or a replay right after sees them.
  """

  @exchange "kick.events"
  @max 200

  @type message :: %{
          message_id: String.t() | nil,
          event_type: String.t() | nil,
          routing_key: String.t(),
          reason: String.t() | nil,
          count: integer() | nil,
          payload: binary(),
          envelope: map() | nil
        }

  @doc "Whether the dead-letter connection is configured."
  def configured?, do: url() != nil

  defp url, do: Application.get_env(:kick_tracker, :dead_letters_amqp_url)

  defp queue,
    do: Application.get_env(:kick_tracker, :amqp_queue, "kick_tracker.events") <> ".dead"

  @doc "Up to `limit` dead letters, oldest first. They all stay in the queue."
  @spec list(pos_integer()) :: {:ok, [message()]} | {:error, term()}
  def list(limit \\ 50) do
    with_channel(fn chan ->
      before = ready(chan)
      {messages, tags} = take(chan, min(limit, @max))
      requeue(chan, tags)
      settle(chan, before)
      Enum.reverse(messages)
    end)
  end

  @doc "How many messages wait in the dead-letter queue."
  @spec count() :: {:ok, non_neg_integer()} | {:error, term()}
  def count do
    with_channel(fn chan ->
      ready(chan)
    end)
  end

  @doc """
  Publishes a dead letter back to `kick.events` with its original routing
  key and properties (so the consumer handles it again), then removes it
  from the dead-letter queue, only once RabbitMQ confirmed the publish.
  """
  @spec replay(String.t()) :: :ok | {:error, term()}
  def replay(message_id) do
    act(message_id, fn chan, m ->
      :ok = AMQP.Confirm.select(chan)

      :ok =
        AMQP.Basic.publish(chan, @exchange, m.routing_key, m.payload,
          content_type: m.meta.content_type,
          message_id: m.message_id,
          type: m.event_type,
          timestamp: m.meta.timestamp,
          persistent: true
        )

      if AMQP.Confirm.wait_for_confirms(chan, 10_000) == true,
        do: :ok,
        else: {:error, :not_confirmed}
    end)
  end

  @doc "Removes a dead letter for good. The caller records why."
  @spec discard(String.t()) :: :ok | {:error, term()}
  def discard(message_id), do: act(message_id, fn _chan, _m -> :ok end)

  # Finds one message by id, runs `fun`, and acknowledges it if `fun`
  # succeeded; everything else taken goes back.
  defp act(message_id, fun) do
    result =
      with_channel(fn chan ->
        before = ready(chan)
        {messages, tags} = take(chan, @max)

        case Enum.find(messages, &(&1.message_id == message_id)) do
          nil ->
            requeue(chan, tags)
            settle(chan, before)
            {:error, :not_found}

          m ->
            outcome = fun.(chan, m)
            if outcome == :ok, do: AMQP.Basic.ack(chan, m.tag)
            requeue(chan, List.delete(tags, m.tag) ++ if(outcome == :ok, do: [], else: [m.tag]))
            settle(chan, if(outcome == :ok, do: before - 1, else: before))
            outcome
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      error -> error
    end
  end

  defp take(chan, limit) do
    Enum.reduce_while(1..limit, {[], []}, fn _, {messages, tags} ->
      case AMQP.Basic.get(chan, queue(), no_ack: false) do
        {:ok, payload, meta} ->
          {:cont, {[message(payload, meta) | messages], [meta.delivery_tag | tags]}}

        {:empty, _} ->
          {:halt, {messages, tags}}
      end
    end)
  end

  defp requeue(chan, tags), do: Enum.each(tags, &AMQP.Basic.nack(chan, &1, requeue: true))

  # Messages ready in the queue (not counting any taken and not yet back).
  defp ready(chan) do
    {:ok, %{message_count: n}} = AMQP.Queue.declare(chan, queue(), passive: true)
    n
  end

  # Waits until the messages put back are ready again (at least
  # `expected`: more may have been dead-lettered meanwhile), for up to 2s.
  defp settle(chan, expected, tries \\ 100) do
    if ready(chan) < expected and tries > 0 do
      Process.sleep(20)
      settle(chan, expected, tries - 1)
    end

    :ok
  end

  defp message(payload, meta) do
    death = first_death(meta.headers)

    %{
      tag: meta.delivery_tag,
      meta: meta,
      message_id: meta.message_id,
      event_type: meta.type,
      routing_key: death[:routing_key] || meta.routing_key,
      reason: death[:reason],
      count: death[:count],
      payload: payload,
      envelope:
        case Jason.decode(payload) do
          {:ok, %{} = e} -> e
          _ -> nil
        end
    }
  end

  # RabbitMQ's x-death header: why and how often, and the original routing key.
  defp first_death(headers) when is_list(headers) do
    case List.keyfind(headers, "x-death", 0) do
      {"x-death", :array, [{:table, fields} | _]} ->
        f = Map.new(fields, fn {k, _t, v} -> {k, v} end)

        %{
          reason: f["reason"],
          count: f["count"],
          routing_key:
            case f["routing-keys"] do
              [{:longstr, key} | _] -> key
              _ -> nil
            end
        }

      _ ->
        %{}
    end
  end

  defp first_death(_), do: %{}

  defp with_channel(fun) do
    case url() do
      nil ->
        {:error, :not_configured}

      url ->
        # See Events.Consumer: the URI parser needs this module loaded.
        Code.ensure_loaded(:amqp_auth_mechanisms)

        with {:ok, conn} <- AMQP.Connection.open(url, connection_timeout: 5_000) do
          try do
            {:ok, chan} = AMQP.Channel.open(conn)
            {:ok, fun.(chan)}
          catch
            :exit, reason -> {:error, reason}
          after
            AMQP.Connection.close(conn)
          end
        end
    end
  end
end
