defmodule Receiver.Peer do
  @moduledoc """
  Whether the other receiver could take this one's deliveries: its
  `/health` answers 200 and says RabbitMQ is connected. Polled in the
  background (`PEER_HEALTH_URL`), so this receiver's own health check never
  waits on the peer.

  Used only to decide when to step aside (project.md §8.4): a receiver that
  has lost RabbitMQ for a while reports itself unhealthy **only if** its
  peer can publish, so the load balancer moves traffic there; when both
  have lost RabbitMQ (the broker is down), both stay healthy and spool.
  """

  use GenServer

  @table __MODULE__
  @poll_ms 3_000
  @timeout_ms 1_000
  # A peer answer older than this counts as no answer.
  @stale_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the peer was last seen able to publish (false without a peer). Never blocks."
  @spec accepting?() :: boolean()
  def accepting? do
    case :ets.lookup(@table, :peer) do
      [{:peer, true, at}] -> System.monotonic_time(:millisecond) - at < @stale_ms
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])

    state = %{
      url: Keyword.get(opts, :url),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      task: nil
    }

    if state.url, do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    url = state.url
    {:noreply, %{state | task: Task.async(fn -> check(url) end)}}
  end

  def handle_info({ref, accepting}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    :ets.insert(@table, {:peer, accepting, System.monotonic_time(:millisecond)})
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    :ets.insert(@table, {:peer, false, System.monotonic_time(:millisecond)})
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Linked to this process: it must not raise.
  defp check(url) do
    case Req.get(url,
           retry: false,
           receive_timeout: @timeout_ms,
           connect_options: [timeout: @timeout_ms]
         ) do
      {:ok, %{status: 200, body: %{"rabbitmq" => true}}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
