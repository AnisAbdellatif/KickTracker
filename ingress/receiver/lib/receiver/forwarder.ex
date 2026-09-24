defmodule Receiver.Forwarder do
  @moduledoc """
  Drains the spool into RabbitMQ once it is reachable again. Each envelope
  is deleted from the spool only after RabbitMQ confirms it, and a batch
  stops at the first failure, so nothing is lost and order within the
  spool is kept. A message forwarded twice (a crash between confirm and
  delete) is harmless: the app ignores repeats by message id.
  """

  use GenServer
  require Logger

  alias Receiver.{Publisher, Spool}

  @batch 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Drains now instead of waiting for the timer. Returns how many were forwarded."
  @spec drain(GenServer.server()) :: non_neg_integer()
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain, :infinity)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      spool: Keyword.get(opts, :spool, Spool),
      publisher: Keyword.get(opts, :publisher, Publisher)
    }

    if state.interval_ms > 0, do: Process.send_after(self(), :drain, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, forward(state), state}

  @impl true
  def handle_info(:drain, state) do
    forwarded = forward(state)
    if forwarded > 0, do: Logger.info("forwarded #{forwarded} spooled envelopes")
    Process.send_after(self(), :drain, state.interval_ms)
    {:noreply, state}
  end

  defp forward(state) do
    if Publisher.connected?(state.publisher), do: forward_batches(state, 0), else: 0
  end

  defp forward_batches(state, total) do
    case Spool.take(@batch, state.spool) do
      [] ->
        total

      rows ->
        {sent, failed?} = forward_rows(rows, state)

        if failed? or length(rows) < @batch,
          do: total + sent,
          else: forward_batches(state, total + sent)
    end
  end

  defp forward_rows(rows, state) do
    Enum.reduce_while(rows, {0, false}, fn {id, _message_id, routing_key, payload}, {sent, _} ->
      envelope = Jason.decode!(payload)

      case Publisher.publish(
             routing_key,
             payload,
             Receiver.Envelope.amqp_options(envelope),
             state.publisher
           ) do
        :ok ->
          Spool.delete(id, state.spool)
          {:cont, {sent + 1, false}}

        {:error, _reason} ->
          {:halt, {sent, true}}
      end
    end)
  end
end
