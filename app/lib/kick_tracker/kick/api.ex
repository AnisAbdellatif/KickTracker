defmodule KickTracker.Kick.API do
  @moduledoc """
  Kick's public API (`<KICK_API_URL>/public/v1`), with the app token.

  Every function returns `{:ok, data}` or `{:error, reason}` and never
  raises: a failed request is a gap for the caller to record, never a
  zero. Batched calls take at most 50 ids, Kick's limit. A 401 drops the
  token and retries once with a new one; a 429 is retried after Kick's
  `retry-after`, capped at 10s, a couple of times at most (a poll cycle
  can't be stalled by a long wait).

  The requests and the reading of the answers are kicksdk's
  (`Kicksdk.PublicApi`); what comes back keeps Kick's own field names
  (`viewer_count`, `started_at`, `active_subscribers_count`, …), with
  anything Kick left out as nil.
  """

  alias KickTracker.Kick.{Endpoints, HTTP, Token}
  alias Kicksdk.PublicApi

  @max_batch 50

  @doc "The live streams among these broadcasters (offline ones are absent)."
  @spec livestreams([integer()]) :: {:ok, [map()]} | {:error, term()}
  def livestreams([]), do: {:ok, []}

  def livestreams(user_ids) when length(user_ids) <= @max_batch,
    do:
      request(
        &hd(PublicApi.livestreams_requests(&1, user_ids, &2)),
        &PublicApi.parse_livestreams/2
      )

  @doc "Channels by broadcaster id."
  @spec channels([integer()]) :: {:ok, [map()]} | {:error, term()}
  def channels([]), do: {:ok, []}

  def channels(user_ids) when length(user_ids) <= @max_batch,
    do:
      request(
        &PublicApi.channels_by_ids_request(&1, user_ids, &2),
        &PublicApi.parse_channels/2
      )

  @doc """
  One channel by slug. An unknown slug is `{:error, :not_found}` (Kick
  answers 400 for the whole request).
  """
  @spec channel_by_slug(String.t()) :: {:ok, map()} | {:error, term()}
  def channel_by_slug(slug) do
    case request(
           &PublicApi.channels_by_slugs_request(&1, [slug], &2),
           &PublicApi.parse_channels/2
         ) do
      {:ok, [channel | _]} -> {:ok, channel}
      {:ok, []} -> {:error, :not_found}
      {:error, {:http, 400, _}} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Every webhook subscription the app has."
  @spec subscriptions() :: {:ok, [map()]} | {:error, term()}
  def subscriptions,
    do: request(&PublicApi.subscriptions_request/2, &PublicApi.parse_subscriptions/2)

  @doc "Subscribes one broadcaster to these event types (version 1)."
  @spec subscribe(integer(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def subscribe(user_id, events),
    do:
      request(
        &PublicApi.subscribe_request(&1, user_id, Enum.map(events, fn e -> {e, 1} end), &2),
        &PublicApi.parse_subscriptions/2
      )

  @doc """
  Removes subscriptions by id, #{@max_batch} per request: Kick answered 400
  to one request removing a few hundred. Stops at the first batch that
  fails; the ones before it are removed.
  """
  @spec unsubscribe([String.t()]) :: :ok | {:error, term()}
  def unsubscribe([]), do: :ok

  def unsubscribe(ids) do
    ids
    |> Enum.chunk_every(@max_batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case request(&hd(PublicApi.unsubscribe_requests(&1, batch, &2)), &accepted/2) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Kick answers a removal with nothing to read.
  defp accepted(status, _body) when status in 200..299, do: {:ok, nil}
  defp accepted(status, body), do: {:error, {:status, status, String.slice(body, 0, 200)}}

  # `build` makes the request from the token and the endpoints; `parse`
  # reads the answer (both kicksdk's).
  defp request(build, parse, retried? \\ false) do
    with {:ok, token} <- Token.get(),
         {:ok, request} <- built(build.(token, Endpoints.get())) do
      result =
        HTTP.send(request,
          retry: &retry?/2,
          max_retries: 2,
          retry_log_level: :warning
        )

      case result do
        {:ok, 401, _body} when not retried? ->
          Token.invalidate(token)
          request(build, parse, true)

        {:ok, status, body} ->
          case HTTP.parse(parse, status, body) do
            {:ok, data} -> {:ok, data}
            # Kept as before kicksdk: callers and logs know `{:http, …}`.
            {:error, {:status, status, excerpt}} -> {:error, {:http, status, excerpt}}
            {:error, reason} -> {:error, reason}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # A builder that can refuse its arguments returns a result; the others,
  # the request itself.
  defp built({:ok, request}), do: {:ok, request}
  defp built({:error, reason}), do: {:error, reason}
  defp built(%{} = request), do: {:ok, request}

  # 429 and transient network errors are worth a retry; anything else is
  # answered at once.
  defp retry?(_request, %Req.Response{status: 429} = response) do
    wait_s =
      with [value | _] <- Req.Response.get_header(response, "retry-after"),
           {s, _} <- Integer.parse(value) do
        s
      else
        _ -> 2
      end

    {:delay, min(max(wait_s, 1), 10) * 1_000}
  end

  defp retry?(_request, %Req.Response{}), do: false
  defp retry?(_request, %{__exception__: true}), do: true
end
