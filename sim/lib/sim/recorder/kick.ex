defmodule Sim.Recorder.Kick do
  @moduledoc """
  The calls the recorder makes to Kick. Each one is recorded into the run
  directory before its result is used, so a run is a complete trace of what
  was asked and what came back.
  """

  alias Sim.Recorder.{Config, HTTP, Store}

  @max_per_request 50

  @doc "Gets an app access token (client credentials). The token itself is redacted on disk."
  @spec token!(Config.t(), Path.t()) :: String.t()
  def token!(config, run) do
    config = Config.require_credentials!(config)

    rec =
      record!(config, run, "id", "token", :post, config.id_url <> "/oauth/token",
        form: [
          grant_type: "client_credentials",
          client_id: config.client_id,
          client_secret: config.client_secret
        ]
      )

    case {HTTP.status(rec), HTTP.json(rec)} do
      {200, %{"access_token" => token}} when is_binary(token) -> token
      {status, _} -> Mix.raise("Kick refused the token request (HTTP #{status}); see #{run}/id")
    end
  end

  @doc "Kick's webhook signing key (PEM), or nil if it couldn't be read."
  @spec public_key(Config.t(), Path.t(), String.t() | nil) :: String.t() | nil
  def public_key(config, run, token \\ nil) do
    rec =
      record!(config, run, "public_api", "public-key", :get, api(config, "/public-key"),
        token: token
      )

    case HTTP.json(rec) do
      %{"data" => %{"public_key" => pem}} when is_binary(pem) -> pem
      %{"public_key" => pem} when is_binary(pem) -> pem
      _ -> nil
    end
  end

  @doc "Channels by slug, 50 per request. Returns the decoded `data` entries."
  @spec channels_by_slugs(Config.t(), Path.t(), String.t(), [String.t()]) :: [map()]
  def channels_by_slugs(config, run, token, slugs) do
    slugs
    |> Enum.chunk_every(@max_per_request)
    |> Enum.flat_map(fn chunk ->
      rec =
        record!(config, run, "public_api", "channels", :get, api(config, "/channels"),
          token: token,
          params: Enum.map(chunk, &{:slug, &1})
        )

      data(rec)
    end)
  end

  @doc "Live streams for broadcaster ids, 50 per request. Returns `{recording, data}` per request."
  @spec livestreams(Config.t(), Path.t(), String.t(), [integer()], String.t()) :: [
          {map(), [map()]}
        ]
  def livestreams(config, run, token, ids, name \\ "livestreams") do
    ids
    |> Enum.chunk_every(@max_per_request)
    |> Enum.map(fn chunk ->
      rec =
        record!(config, run, "public_api", name, :get, api(config, "/livestreams"),
          token: token,
          params: Enum.map(chunk, &{:broadcaster_user_id, &1})
        )

      {rec, data(rec)}
    end)
  end

  @doc "Kick's private v2 channel endpoint (no token). `playback_url` is redacted on disk."
  @spec v2_channel(Config.t(), Path.t(), String.t()) :: map() | nil
  def v2_channel(config, run, slug) do
    rec =
      record!(
        config,
        run,
        "v2",
        "channel",
        :get,
        config.v2_url <> "/channels/" <> URI.encode(slug)
      )

    if HTTP.status(rec) == 200, do: HTTP.json(rec)
  end

  @spec list_subscriptions(Config.t(), Path.t(), String.t()) :: [map()]
  def list_subscriptions(config, run, token) do
    url = api(config, "/events/subscriptions")
    rec = record!(config, run, "public_api", "subscriptions-list", :get, url, token: token)
    data(rec)
  end

  @spec subscribe(Config.t(), Path.t(), String.t(), integer(), [String.t()]) :: [map()]
  def subscribe(config, run, token, broadcaster_user_id, events) do
    rec =
      record!(
        config,
        run,
        "public_api",
        "subscriptions-create",
        :post,
        api(config, "/events/subscriptions"),
        token: token,
        json: %{
          "broadcaster_user_id" => broadcaster_user_id,
          "events" => Enum.map(events, &%{"name" => &1, "version" => 1}),
          "method" => "webhook"
        }
      )

    data(rec)
  end

  @spec unsubscribe(Config.t(), Path.t(), String.t(), [String.t()]) :: integer()
  def unsubscribe(_config, _run, _token, []), do: 204

  def unsubscribe(config, run, token, ids) do
    config
    |> record!(
      run,
      "public_api",
      "subscriptions-delete",
      :delete,
      api(config, "/events/subscriptions"),
      token: token,
      params: Enum.map(ids, &{:id, &1})
    )
    |> HTTP.status()
  end

  @doc "Makes a request, records it, and returns the recording. Raises only if Kick can't be reached."
  @spec record!(Config.t(), Path.t(), String.t(), String.t(), atom(), String.t(), keyword()) ::
          map()
  def record!(config, run, source, name, method, url, opts \\ []) do
    case HTTP.request(config, method, url, opts) do
      {:ok, rec} ->
        Store.write(run, source, name, rec)
        rec

      {:error, reason} ->
        Mix.raise("could not reach #{url}: #{Exception.message(reason)}")
    end
  end

  defp api(config, path), do: config.api_url <> "/public/v1" <> path

  defp data(rec) do
    case HTTP.json(rec) do
      %{"data" => data} when is_list(data) -> data
      _ -> []
    end
  end
end
