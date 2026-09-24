defmodule KickTracker.Events.Consumer do
  @moduledoc """
  Reads envelopes from `kick_tracker.events` (project.md §8, §10).

  Each message is decoded and its signature checked again. A message that
  can't be decoded or doesn't verify is **rejected to the dead-letter
  queue**, to be looked at by hand, never retried in a loop.

  Good messages are stored in batches, one transaction per batch
  (`KickTracker.Events.ingest/1`), and **acknowledged only after the
  commit**. If the database is unreachable, the batch waits and retries
  with backoff, holding its messages unacknowledged: an outage must not
  push good events into the dead-letter queue through RabbitMQ's delivery
  limit. If one message in a batch breaks the transaction for another
  reason, the batch is stored one message at a time, so only the bad one is
  dead-lettered.

  After the commit, stream status and metadata events go to their
  channel's process (`KickTracker.Tracking`); if it isn't running, they stay
  unprocessed in the database and it catches up when it starts.
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias KickTracker.Events
  alias KickTracker.Events.Envelope
  alias KickTracker.Kick.PublicKey

  @max_backoff_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Broadway.start_link(__MODULE__,
      name: Keyword.get(opts, :name, __MODULE__),
      context: %{
        public_key: Keyword.get(opts, :public_key, PublicKey),
        dispatch: Keyword.get(opts, :dispatch, &KickTracker.Tracking.dispatch/1)
      },
      producer: [module: Keyword.get_lazy(opts, :producer, &producer/0), concurrency: 1],
      processors: [default: [concurrency: 4]],
      batchers: [default: [batch_size: 50, batch_timeout: 200, concurrency: 2]]
    )
  end

  # RabbitMQ, with the consume-only user. Failed messages are requeued by
  # default; the ones that can never succeed are rejected explicitly.
  defp producer do
    # The AMQP URI parser turns mechanism names into atoms with
    # `list_to_existing_atom`, and `amqplain` only exists once this module
    # is loaded. A release loads everything at boot; `mix run` loads lazily,
    # and the consumer then refuses a perfectly good URL.
    Code.ensure_loaded!(:amqp_auth_mechanisms)

    {BroadwayRabbitMQ.Producer,
     queue: Application.get_env(:kick_tracker, :amqp_queue, "kick_tracker.events"),
     connection: Application.fetch_env!(:kick_tracker, :amqp_url),
     qos: [prefetch_count: 200],
     on_success: :ack,
     on_failure: :reject_and_requeue,
     backoff_type: :exp,
     backoff_min: 1_000,
     backoff_max: 30_000}
  end

  @impl true
  def handle_message(_processor, %Message{} = message, context) do
    with {:ok, envelope} <- Envelope.decode(message.data),
         :ok <- verify(envelope, context.public_key) do
      Message.put_data(message, envelope)
    else
      {:error, reason} -> dead_letter(message, reason)
    end
  end

  @impl true
  def handle_batch(_batcher, messages, _batch_info, context) do
    envelopes = Enum.map(messages, & &1.data)

    case store(envelopes) do
      {:ok, new} ->
        context.dispatch.(new)
        messages

      {:error, _reason} ->
        # Something in this batch breaks the transaction: store one by one.
        Enum.map(messages, &store_one(&1, context))
    end
  end

  defp store_one(message, context) do
    case store([message.data]) do
      {:ok, new} ->
        context.dispatch.(new)
        message

      {:error, reason} ->
        dead_letter(message, {:store_failed, reason})
    end
  end

  # The database being down is waited out; anything else is returned.
  defp store(envelopes, backoff_ms \\ 500) do
    Events.ingest(envelopes)
  rescue
    error in DBConnection.ConnectionError ->
      Logger.warning(
        "database unavailable (#{Exception.message(error)}), retrying in #{backoff_ms}ms"
      )

      Process.sleep(backoff_ms)
      store(envelopes, min(backoff_ms * 2, @max_backoff_ms))

    error ->
      {:error, error}
  end

  # A signature that fails may mean Kick rotated its key: fetch it again
  # (at most once a minute) before giving up on the message. No key at all
  # is waited out, not held against the message.
  defp verify(envelope, server) do
    pem = await_key(server)

    cond do
      Envelope.verified?(envelope, pem) -> :ok
      Envelope.verified?(envelope, PublicKey.refresh(server)) -> :ok
      true -> {:error, :bad_signature}
    end
  end

  defp await_key(server, waited_ms \\ 0) do
    case PublicKey.get(server) do
      nil ->
        if rem(waited_ms, 30_000) == 0, do: Logger.warning("waiting for Kick's public key")
        Process.sleep(1_000)
        await_key(server, waited_ms + 1_000)

      pem ->
        pem
    end
  end

  defp dead_letter(message, reason) do
    Logger.error("dead-lettering a message: #{inspect(reason)}")

    message
    |> Message.configure_ack(on_failure: :reject)
    |> Message.failed(reason)
  end
end
