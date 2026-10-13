defmodule KickTracker.Kick.V2 do
  @moduledoc """
  Kick's private v2 channel endpoint (`<KICK_V2_URL>/channels/<slug>`),
  isolated here so it can be replaced (project.md §2.3). kicksdk builds the
  request and reads the answer (`Kicksdk.Website`).

  Two fields are kept and everything else is dropped on the spot: the
  **follower total**, and the **chatroom id** needed to join the channel's
  chat. The response also carries a signed `playback_url`; it never leaves
  this function, and neither the raw response nor kicksdk's reading of it
  is ever logged.

  `followers_count` has come as a number in one recording and a string in
  another; kicksdk reads both. Anything unexpected is an error, which the
  caller records as a gap.
  """

  alias KickTracker.Kick.{Endpoints, HTTP}

  @doc "The follower total and chatroom id for a channel."
  @spec channel(String.t()) ::
          {:ok, %{followers: non_neg_integer(), chatroom_id: integer()}} | {:error, term()}
  def channel(slug) do
    case HTTP.send(Kicksdk.Website.channel_request(slug, Endpoints.get())) do
      {:ok, status, body} -> extract(status, body)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  # Public for tests: what is kept from an answer.
  def extract(status, body) do
    case HTTP.parse(&Kicksdk.Website.parse_channel/2, status, body) do
      {:ok, %{"followers_count" => followers, "chatroom_id" => chatroom_id}}
      when is_integer(followers) and followers >= 0 ->
        {:ok, %{followers: followers, chatroom_id: chatroom_id}}

      # Only the status: the excerpt kicksdk keeps of the body may hold the
      # signed playback URL.
      {:error, {:status, status, _excerpt}} ->
        {:error, {:http, status}}

      _ ->
        {:error, :unexpected_response}
    end
  end
end
