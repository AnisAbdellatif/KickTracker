defmodule Receiver.PublicKey do
  @moduledoc """
  Kick's webhook signing key: given in configuration, or fetched from
  `GET <KICK_API_URL>/public/v1/public-key` and kept.

  If a signature fails, the key may have changed: `refresh/0` fetches it
  again, at most once a minute, so a flood of bad requests can't turn the
  receiver into a way to hammer Kick's API.
  """

  use GenServer
  require Logger

  @refresh_every_ms 60_000
  @retry_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The key in PEM form, or nil while it hasn't been fetched yet."
  @spec get(GenServer.server()) :: String.t() | nil
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @doc "Fetches the key again, unless that was done in the last minute. Returns the key."
  @spec refresh(GenServer.server()) :: String.t() | nil
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 15_000)

  @impl true
  def init(opts) do
    state = %{pem: Keyword.get(opts, :pem), api_url: Keyword.get(opts, :api_url), fetched_at: nil}
    if state.pem == nil, do: send(self(), :fetch)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.pem, state}

  def handle_call(:refresh, _from, state) do
    state = if recently_fetched?(state), do: state, else: fetch(state)
    {:reply, state.pem, state}
  end

  @impl true
  def handle_info(:fetch, state) do
    state = fetch(state)
    if state.pem == nil, do: Process.send_after(self(), :fetch, @retry_ms)
    {:noreply, state}
  end

  defp fetch(%{api_url: nil} = state), do: state

  defp fetch(state) do
    url = state.api_url <> "/public/v1/public-key"
    now = System.monotonic_time(:millisecond)

    case Req.get(url, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => %{"public_key" => pem}}}} when is_binary(pem) ->
        %{state | pem: pem, fetched_at: now}

      other ->
        Logger.warning("could not fetch Kick's public key from #{url}: #{inspect(other)}")
        %{state | fetched_at: now}
    end
  end

  defp recently_fetched?(%{fetched_at: nil}), do: false

  defp recently_fetched?(%{fetched_at: at}),
    do: System.monotonic_time(:millisecond) - at < @refresh_every_ms
end
