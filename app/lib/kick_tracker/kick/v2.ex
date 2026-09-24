defmodule KickTracker.Kick.V2 do
  @moduledoc """
  Kick's private v2 channel endpoint (`<KICK_V2_URL>/channels/<slug>`),
  isolated here so it can be replaced (project.md §2.3).

  Two fields are read and everything else is dropped on the spot: the
  **follower total**, and the **chatroom id** needed to join the channel's
  chat. The response also carries a signed `playback_url`; it never leaves
  this function, and the raw response is never logged.

  `followers_count` has come as a number in one recording and a string in
  another, so both are accepted. Anything unexpected is an error, which
  the caller records as a gap.
  """

  @doc "The follower total and chatroom id for a channel."
  @spec channel(String.t()) ::
          {:ok, %{followers: non_neg_integer(), chatroom_id: integer() | nil}} | {:error, term()}
  def channel(slug) do
    base = Application.fetch_env!(:kick_tracker, :kick)[:v2_url]

    case Req.get(base <> "/channels/" <> URI.encode(slug, &URI.char_unreserved?/1),
           retry: false,
           receive_timeout: 15_000,
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %{status: 200, body: body}} -> extract(body)
      # Only the status: the body may hold the signed playback URL.
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  # Public for tests: what is kept from a response body.
  def extract(%{"followers_count" => count} = body) do
    with {:ok, followers} <- count(count) do
      chatroom_id =
        case body["chatroom"] do
          %{"id" => id} when is_integer(id) -> id
          _ -> nil
        end

      {:ok, %{followers: followers, chatroom_id: chatroom_id}}
    end
  end

  def extract(_), do: {:error, :unexpected_response}

  defp count(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :unexpected_response}
    end
  end

  defp count(_), do: {:error, :unexpected_response}
end
