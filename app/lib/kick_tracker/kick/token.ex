defmodule KickTracker.Kick.Token do
  @moduledoc """
  The app access token (client credentials, `POST <KICK_ID_URL>/oauth/token`,
  asked and read by kicksdk).

  Fetched on first use and replaced ahead of expiry (Kick's last 60
  days): at 90% of its life a new one is fetched while the old one keeps
  serving, and a failed refresh is retried every minute rather than
  dropping a token that still works. A request that gets 401 calls `invalidate/1` with the token it
  used, and the next `get/0` fetches a fresh one; invalidating a token
  that was already replaced does nothing, so many failing requests cause
  one fetch.
  """

  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "A valid token, fetching one if needed."
  @spec get(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get(server \\ __MODULE__), do: GenServer.call(server, :get, 30_000)

  @doc "Drops this token (the API refused it)."
  @spec invalidate(String.t(), GenServer.server()) :: :ok
  def invalidate(token, server \\ __MODULE__), do: GenServer.cast(server, {:invalidate, token})

  @impl true
  def init(opts) do
    kick = Application.get_env(:kick_tracker, :kick, [])

    {:ok,
     %{
       id_url: Keyword.get(opts, :id_url, kick[:id_url]),
       client_id: Keyword.get(opts, :client_id, kick[:client_id]),
       client_secret: Keyword.get(opts, :client_secret, kick[:client_secret]),
       token: nil,
       refresh_timer: nil
     }}
  end

  @impl true
  def handle_call(:get, _from, %{token: token} = state) when is_binary(token),
    do: {:reply, {:ok, token}, state}

  def handle_call(:get, _from, state) do
    case fetch(state) do
      {:ok, token, expires_in} ->
        {:reply, {:ok, token}, schedule_refresh(%{state | token: token}, expires_in)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:invalidate, token}, %{token: token} = state),
    do: {:noreply, %{state | token: nil}}

  def handle_cast({:invalidate, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info(:refresh, state) do
    case fetch(state) do
      {:ok, token, expires_in} ->
        {:noreply, schedule_refresh(%{state | token: token, refresh_timer: nil}, expires_in)}

      {:error, _} ->
        {:noreply, %{state | refresh_timer: Process.send_after(self(), :refresh, 60_000)}}
    end
  end

  defp fetch(state) do
    endpoints = KickTracker.Kick.Endpoints.get(id_url: state.id_url)
    request = Kicksdk.PublicApi.app_token_request(state.client_id, state.client_secret, endpoints)

    case KickTracker.Kick.HTTP.send(request) do
      {:ok, status, body} ->
        case Kicksdk.PublicApi.parse_app_token(status, body) do
          {:ok, %{"access_token" => token} = parsed} ->
            {:ok, token, parsed["expires_in"]}

          {:error, {:status, status, _excerpt}} ->
            Logger.error("Kick refused the token request (HTTP #{status})")
            {:error, {:http, status}}

          {:error, reason} ->
            Logger.error("Kick's token answer could not be read: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, error} ->
        Logger.warning("token request failed: #{Exception.message(error)}")
        {:error, error}
    end
  end

  # Refresh at 90% of the lifetime, so a token never expires mid-use.
  defp schedule_refresh(state, expires_in) when is_integer(expires_in) and expires_in > 0 do
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)
    ms = min(div(expires_in * 900, 1), 4_000_000_000)
    %{state | refresh_timer: Process.send_after(self(), :refresh, ms)}
  end

  defp schedule_refresh(state, _), do: state
end
