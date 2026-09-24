defmodule KickTracker.Events.Consumer do
  @moduledoc """
  Reads envelopes from `kick_tracker.events` (project.md §8, §10).

  Each message is decoded and its signature checked again. A message that
  can't be decoded or doesn't verify is **rejected to the dead-letter
  queue**, to be looked at by hand, never retried in a loop.

  Good messages are stored in batches, one transaction per batch
  (`KickTracker.Events.ingest/1`), and **acknowledged only after the
  commit**. If the database is unreachable or unable to take writes for a
  while (see `transient?/1`: a lost connection, a shutdown or failover,
  a read-only replica, a full disk, a statement timeout, a serialization
  failure or deadlock), the batch waits and retries with backoff, holding
  its messages unacknowledged: an outage must not push good events into
  the dead-letter queue through RabbitMQ's delivery limit. If one message
  in a batch breaks the transaction for another reason, the batch is
  stored one message at a time, so only the bad one is dead-lettered.

  A signature that fails is checked again with a freshly fetched key (Kick
  may have rotated it). If that fetch can't finish in time, the message is
  requeued rather than dead-lettered: the key being unknown is not the
  message's fault.

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
        dispatch: Keyword.get(opts, :dispatch, &KickTracker.Tracking.dispatch/1),
        ingest: Keyword.get(opts, :ingest, &Events.ingest/1),
        # How long a failed signature waits for Kick's key to be fetched again.
        key_wait_ms: Keyword.get(opts, :key_wait_ms, 15_000)
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
         :ok <- verify(envelope, context) do
      Message.put_data(message, envelope)
    else
      # Requeued (the producer's default for a failure), not dead-lettered.
      {:error, :key_unavailable} -> Message.failed(message, :key_unavailable)
      {:error, reason} -> dead_letter(message, reason)
    end
  end

  @impl true
  def handle_batch(_batcher, messages, _batch_info, context) do
    envelopes = Enum.map(messages, & &1.data)

    case store(envelopes, context) do
      {:ok, new} ->
        context.dispatch.(new)
        messages

      {:error, _reason} ->
        # Something in this batch breaks the transaction: store one by one.
        Enum.map(messages, &store_one(&1, context))
    end
  end

  defp store_one(message, context) do
    case store([message.data], context) do
      {:ok, new} ->
        context.dispatch.(new)
        message

      {:error, reason} ->
        dead_letter(message, {:store_failed, reason})
    end
  end

  # The database being unavailable is waited out; anything else is returned.
  defp store(envelopes, context, backoff_ms \\ 500) do
    case context.ingest.(envelopes) do
      {:error, reason} = error ->
        if transient?(reason),
          do: wait_and_store(envelopes, context, backoff_ms, reason),
          else: error

      ok ->
        ok
    end
  rescue
    error ->
      if transient?(error),
        do: wait_and_store(envelopes, context, backoff_ms, error),
        else: {:error, error}
  end

  defp wait_and_store(envelopes, context, backoff_ms, reason) do
    Logger.warning("database unavailable (#{describe(reason)}), retrying in #{backoff_ms}ms")
    Process.sleep(backoff_ms)
    store(envelopes, context, min(backoff_ms * 2, @max_backoff_ms))
  end

  # SQLSTATE classes that say the database can't take the write right now,
  # not that the write is wrong: 08 connection exception, 53 insufficient
  # resources (disk full, out of memory, too many connections), 57 operator
  # intervention (shutdown, crash recovery, statement timeout, cancel), 58
  # system error (I/O).
  @transient_classes ~w(08 53 57 58)
  # And single codes: serialization failure, deadlock, read-only
  # transaction (a failover to a replica), lock not available.
  @transient_codes ~w(40001 40P01 25006 55P03)

  @doc """
  Whether a storage error means "try again later" rather than "this
  message can't be stored": the connection is gone, or Postgres answered
  with a SQLSTATE of the classes and codes above.
  """
  @spec transient?(term()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true

  def transient?(%Postgrex.Error{postgres: %{pg_code: code}}) when is_binary(code),
    do: code in @transient_codes or binary_part(code, 0, 2) in @transient_classes

  def transient?(_), do: false

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)

  # A signature that fails may mean Kick rotated its key: fetch it again
  # (at most once a minute) before giving up on the message, and retry
  # only with a key that is different. No key at all, or a fetch that
  # doesn't finish in time, is not held against the message.
  defp verify(envelope, %{public_key: server, key_wait_ms: wait_ms}) do
    pem = await_key(server)

    if Envelope.verified?(envelope, pem) do
      :ok
    else
      case PublicKey.refresh(server, wait_ms) do
        {:ok, new} when new not in [nil, pem] ->
          if Envelope.verified?(envelope, new), do: :ok, else: {:error, :bad_signature}

        {:ok, _same} ->
          {:error, :bad_signature}

        {:error, :timeout} ->
          {:error, :key_unavailable}
      end
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
