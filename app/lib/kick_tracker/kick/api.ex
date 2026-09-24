defmodule KickTracker.Kick.API do
  @moduledoc """
  Kick's public API (`<KICK_API_URL>/public/v1`), with the app token.

  Every function returns `{:ok, data}` or `{:error, reason}` and never
  raises: a failed request is a gap for the caller to record, never a
  zero. Batched calls take at most 50 ids, Kick's limit. A 401 drops the
  token and retries once with a new one; a 429 is retried after Kick's
  `retry-after`, a couple of times at most.
  """

  alias KickTracker.Kick.Token

  @max_batch 50

  @doc "The live streams among these broadcasters (offline ones are absent)."
  @spec livestreams([integer()]) :: {:ok, [map()]} | {:error, term()}
  def livestreams([]), do: {:ok, []}

  def livestreams(user_ids) when length(user_ids) <= @max_batch,
    do: get("/livestreams", Enum.map(user_ids, &{"broadcaster_user_id", &1}))

  @doc "Channels by broadcaster id."
  @spec channels([integer()]) :: {:ok, [map()]} | {:error, term()}
  def channels([]), do: {:ok, []}

  def channels(user_ids) when length(user_ids) <= @max_batch,
    do: get("/channels", Enum.map(user_ids, &{"broadcaster_user_id", &1}))

  @doc """
  One channel by slug. An unknown slug is `{:error, :not_found}` (Kick
  answers 400 for the whole request).
  """
  @spec channel_by_slug(String.t()) :: {:ok, map()} | {:error, term()}
  def channel_by_slug(slug) do
    case get("/channels", [{"slug", slug}]) do
      {:ok, [channel | _]} -> {:ok, channel}
      {:ok, []} -> {:error, :not_found}
      {:error, {:http, 400, _}} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Every webhook subscription the app has."
  @spec subscriptions() :: {:ok, [map()]} | {:error, term()}
  def subscriptions, do: get("/events/subscriptions", [])

  @doc "Subscribes one broadcaster to these event types (version 1)."
  @spec subscribe(integer(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def subscribe(user_id, events) do
    body = %{
      "broadcaster_user_id" => user_id,
      "events" => Enum.map(events, &%{"name" => &1, "version" => 1}),
      "method" => "webhook"
    }

    request(:post, "/events/subscriptions", json: body)
  end

  @doc "Removes subscriptions by id."
  @spec unsubscribe([String.t()]) :: :ok | {:error, term()}
  def unsubscribe([]), do: :ok

  def unsubscribe(ids) do
    case request(:delete, "/events/subscriptions", params: Enum.map(ids, &{"id", &1})) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp get(path, params), do: request(:get, path, params: params)

  defp request(method, path, opts, retried? \\ false) do
    with {:ok, token} <- Token.get() do
      url = Application.fetch_env!(:kick_tracker, :kick)[:api_url] <> "/public/v1" <> path

      result =
        Req.request(
          [
            method: method,
            url: url,
            auth: {:bearer, token},
            receive_timeout: 15_000,
            retry: &retry?/2,
            max_retries: 2,
            retry_log_level: :warning
          ] ++ opts
        )

      case result do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, data(body)}

        {:ok, %{status: 401}} when not retried? ->
          Token.invalidate(token)
          request(method, path, opts, true)

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # 429 and transient network errors are worth a retry; anything else is
  # answered at once.
  defp retry?(_request, %Req.Response{status: 429}), do: true
  defp retry?(_request, %Req.Response{}), do: false
  defp retry?(_request, %{__exception__: true}), do: true

  defp data(%{"data" => data}), do: data
  defp data(""), do: nil
  defp data(other), do: other
end
