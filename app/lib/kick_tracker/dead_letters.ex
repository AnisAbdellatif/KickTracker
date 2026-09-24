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

  A message is named by its `key`, a hash of its `message_id` and its
  bytes: a message without an id still has one, and copies of the same
  message share it (listed once, with how many copies; acted on
  together). Replaying and discarding look through the whole queue (up to
  #{20_000} messages), not only the first page listed.

  A message naming a Kick id whose removal was carried out
  (`KickTracker.Removals`: a privacy deletion, a channel's data deleted)
  is shown with them redacted and can't be replayed, which would bring
  them back; it can only be discarded.
  """

  import Ecto.Query

  alias KickTracker.{Privacy, Repo}

  @exchange "kick.events"
  @max 200
  @scan_max 20_000

  @type message :: %{
          key: String.t(),
          message_id: String.t() | nil,
          event_type: String.t() | nil,
          routing_key: String.t(),
          reason: String.t() | nil,
          count: integer() | nil,
          copies: pos_integer(),
          erased: [integer()],
          payload: binary(),
          envelope: map() | nil
        }

  @doc "Whether the dead-letter connection is configured."
  def configured?, do: url() != nil

  defp url, do: Application.get_env(:kick_tracker, :dead_letters_amqp_url)

  defp queue,
    do: Application.get_env(:kick_tracker, :amqp_queue, "kick_tracker.events") <> ".dead"

  @doc """
  Up to `limit` dead letters (at most #{@max}), oldest first, copies of
  one message listed once. They all stay in the queue.
  """
  @spec list(pos_integer()) :: {:ok, [message()]} | {:error, term()}
  def list(limit \\ 50) do
    with_channel(fn chan ->
      before = ready(chan)
      {messages, tags} = take(chan, min(limit, @max))
      requeue(chan, tags)
      settle(chan, before)

      messages
      |> Enum.reverse()
      |> Enum.group_by(& &1.key)
      |> Enum.map(fn {_key, [m | _] = copies} -> %{m | copies: length(copies)} end)
      |> Enum.sort_by(& &1.tag)
      |> mark_erased()
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
  (every copy) from the dead-letter queue, only once RabbitMQ confirmed
  the publish. `id` is the message's `key`, or its `message_id` when that
  names one message. Refused for a message naming a removed Kick id.
  """
  @spec replay(String.t()) :: :ok | {:error, term()}
  def replay(id) do
    act(id, fn chan, m ->
      case mark_erased([m]) do
        [%{erased: []}] ->
          :ok = AMQP.Confirm.select(chan)

          :ok =
            AMQP.Basic.publish(chan, @exchange, m.routing_key, m.payload,
              content_type: m.meta.content_type,
              message_id: m.message_id || :undefined,
              type: m.event_type || :undefined,
              timestamp: m.meta.timestamp,
              persistent: true
            )

          # The timeout is in seconds (the AMQP library's convention).
          if AMQP.Confirm.wait_for_confirms(chan, {10, :second}) == true,
            do: :ok,
            else: {:error, :not_confirmed}

        [%{erased: [_ | _]}] ->
          {:error, :erased}
      end
    end)
  end

  @doc "Removes a dead letter (every copy) for good. The caller records why."
  @spec discard(String.t()) :: :ok | {:error, term()}
  def discard(id), do: act(id, fn _chan, _m -> :ok end)

  @doc """
  A stable name for a message: its id and bytes hashed, short enough for
  a DOM id. Pure.
  """
  @spec key(String.t() | nil, binary()) :: String.t()
  def key(message_id, payload) do
    :crypto.hash(:sha256, [message_id || "", 0, payload])
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  # Finds the message by key (or message id) in the whole queue, runs
  # `fun` on it, and acknowledges every copy if `fun` succeeded;
  # everything else taken goes back. Two different messages under one
  # message id are ambiguous: name one by its key.
  defp act(id, fun) do
    result =
      with_channel(fn chan ->
        before = ready(chan)
        {messages, tags} = take(chan, @scan_max)

        matches =
          Enum.filter(messages, &(&1.key == id or (&1.message_id != nil and &1.message_id == id)))

        outcome =
          try do
            case Enum.uniq_by(matches, & &1.key) do
              [] -> {:error, :not_found}
              [m] -> fun.(chan, m)
              [_, _ | _] -> {:error, :ambiguous}
            end
          rescue
            e -> {:error, Exception.message(e)}
          end

        done = if outcome == :ok, do: Enum.map(matches, & &1.tag), else: []
        Enum.each(done, &AMQP.Basic.ack(chan, &1))
        requeue(chan, tags -- done)
        settle(chan, before - length(done))
        outcome
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

  # Which removed Kick ids each message names (`erased`), with those
  # redacted from the envelope shown. Only ids in the body's id fields
  # (and lists of ids) count, as for a privacy deletion's scrub.
  defp mark_erased(messages) do
    ids = Map.new(messages, &{&1.key, body_ids(&1.envelope)})
    all = ids |> Map.values() |> Enum.concat() |> Enum.uniq()

    removed =
      if all == [],
        do: MapSet.new(),
        else:
          Repo.all(
            from r in "removals",
              where: r.kick_user_id in ^all,
              select: r.kick_user_id,
              distinct: true
          )
          |> MapSet.new()

    for m <- messages do
      case ids[m.key]
           |> Enum.filter(&MapSet.member?(removed, &1))
           |> Enum.uniq()
           |> Enum.sort() do
        [] -> %{m | erased: []}
        erased -> %{m | erased: erased, envelope: redact(m.envelope, erased)}
      end
    end
  end

  defp body_ids(%{"body" => body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> json |> ids_in(false) |> Enum.uniq()
      _ -> []
    end
  end

  defp body_ids(_), do: []

  defp ids_in(%{} = map, _in_list?) do
    Enum.flat_map(map, fn
      {k, v} when is_integer(v) -> if k == "id" or String.ends_with?(k, "_id"), do: [v], else: []
      {_k, v} -> ids_in(v, false)
    end)
  end

  defp ids_in(list, _) when is_list(list),
    do: Enum.flat_map(list, fn v -> if is_integer(v), do: [v], else: ids_in(v, true) end)

  defp ids_in(_, _), do: []

  defp redact(%{"body" => body} = envelope, erased) do
    scrubbed = Enum.reduce(erased, Jason.decode!(body), &Privacy.scrub(&2, &1))
    %{envelope | "body" => Jason.encode!(scrubbed)}
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
    # A property the publisher left out comes as :undefined.
    message_id = defined(meta.message_id)

    %{
      key: key(message_id, payload),
      tag: meta.delivery_tag,
      meta: meta,
      copies: 1,
      erased: [],
      message_id: message_id,
      event_type: defined(meta.type),
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

  defp defined(:undefined), do: nil
  defp defined(value), do: value

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
