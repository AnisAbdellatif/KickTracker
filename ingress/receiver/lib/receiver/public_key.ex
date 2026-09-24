defmodule Receiver.PublicKey do
  @moduledoc """
  Kick's webhook signing key: given in configuration, or fetched from
  `GET <KICK_API_URL>/public/v1/public-key` and kept.

  Reading the key never waits: it lives in `:persistent_term`, so a slow
  or unreachable Kick API can't hold up a delivery. Fetches run in a task,
  never in this process.

  If a signature fails, the key may have changed: `refresh/2` starts a
  fetch, at most once a minute (so a flood of bad requests can't turn the
  receiver into a way to hammer Kick's API), and waits for its result for
  a bounded time. Callers already waiting share the fetch in flight.
  """

  use GenServer
  require Logger

  @refresh_every_ms 60_000
  @retry_ms 5_000
  @fetch_timeout_ms 10_000
  @refresh_wait_ms 3_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The key in PEM form, or nil while it hasn't been fetched yet. Never blocks."
  @spec get(atom()) :: String.t() | nil
  def get(name \\ __MODULE__), do: :persistent_term.get(key(name), nil)

  @doc """
  Fetches the key again, unless that was done in the last minute, and
  returns the key then held. Waits at most `wait_ms` for the fetch; after
  that (or if this process is unavailable) it returns the key held now.
  """
  @spec refresh(atom(), timeout()) :: String.t() | nil
  def refresh(name \\ __MODULE__, wait_ms \\ @refresh_wait_ms) do
    GenServer.call(name, :refresh, wait_ms)
  catch
    :exit, _ -> get(name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    pem = Keyword.get(opts, :pem)
    put(name, pem)

    state = %{
      name: name,
      api_url: Keyword.get(opts, :api_url),
      fetch_timeout_ms: Keyword.get(opts, :fetch_timeout_ms, @fetch_timeout_ms),
      fetched_at: nil,
      task: nil,
      waiting: []
    }

    {:ok, if(pem == nil, do: start_fetch(state), else: state)}
  end

  @impl true
  def handle_call(:refresh, from, state) do
    cond do
      state.task != nil -> {:noreply, %{state | waiting: [from | state.waiting]}}
      recently_fetched?(state) or state.api_url == nil -> {:reply, get(state.name), state}
      true -> {:noreply, %{start_fetch(state) | waiting: [from]}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish(state, {:error, reason})}
  end

  def handle_info(:fetch, %{task: nil} = state) do
    {:noreply, if(get(state.name) == nil, do: start_fetch(state), else: state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :persistent_term.erase(key(state.name))

  defp start_fetch(%{api_url: nil} = state), do: state

  defp start_fetch(state) do
    url = state.api_url <> "/public/v1/public-key"
    timeout = state.fetch_timeout_ms
    task = Task.async(fn -> fetch(url, timeout) end)
    %{state | task: task, fetched_at: System.monotonic_time(:millisecond)}
  end

  defp finish(state, result) do
    case result do
      {:ok, pem} ->
        put(state.name, pem)

      {:error, reason} ->
        Logger.warning("could not fetch Kick's public key: #{inspect(reason)}")
    end

    pem = get(state.name)
    Enum.each(state.waiting, &GenServer.reply(&1, pem))
    # With no key at all, keep trying until there is one.
    if pem == nil, do: Process.send_after(self(), :fetch, @retry_ms)
    %{state | task: nil, waiting: []}
  end

  # Linked to this process: it must not raise.
  defp fetch(url, timeout) do
    case Req.get(url, retry: false, receive_timeout: timeout, connect_options: [timeout: timeout]) do
      {:ok, %{status: 200, body: %{"data" => %{"public_key" => pem}}}} when is_binary(pem) ->
        {:ok, pem}

      other ->
        {:error, {url, other}}
    end
  rescue
    error -> {:error, {url, Exception.message(error)}}
  end

  defp recently_fetched?(%{fetched_at: nil}), do: false

  defp recently_fetched?(%{fetched_at: at}),
    do: System.monotonic_time(:millisecond) - at < @refresh_every_ms

  # Written only when the key changes (at start and on rotation), which is
  # what `:persistent_term` is for.
  defp put(name, pem) do
    if :persistent_term.get(key(name), :none) != pem, do: :persistent_term.put(key(name), pem)
  end

  defp key(name), do: {__MODULE__, name}
end
