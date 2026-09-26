defmodule KickTracker.Avatars do
  @moduledoc """
  Channel avatars (project.md §12.9). Kick gives a channel's picture as a
  URL in `/livestreams` answers and in its stream events
  (`profile_picture`); the channel's process records it in
  `channels.avatar_url` when it changes, and `Workers.ChannelAvatar`
  copies the image into `channel_avatars`. The site serves the copy from
  its own domain, so a visitor's browser never contacts Kick.

  Only raster images are kept (PNG, JPEG, GIF, WebP, recognised by their
  first bytes, whatever the server said), up to #{div(1_048_576, 1024)} KB:
  an SVG can carry script, and the bytes are served back as they came.
  Hidden channels' avatars are not served.
  """

  import Ecto.Query
  alias KickTracker.{Cache, Repo}

  @max_bytes 1_048_576

  @doc """
  The image type of these bytes, from their signature; nil for anything
  that isn't a PNG, JPEG, GIF or WebP. Pure.
  """
  @spec sniff(binary()) :: String.t() | nil
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: "image/gif"
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(_), do: nil

  @doc "A picture URL worth fetching: http(s), with a host."
  @spec fetchable?(term()) :: boolean()
  def fetchable?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def fetchable?(_), do: false

  @doc """
  Downloads a picture: `{:ok, content_type, bytes}`, or `{:error, reason}`
  (not an accepted image, too large, an HTTP error, unreachable).
  """
  @spec download(String.t()) :: {:ok, String.t(), binary()} | {:error, term()}
  def download(url) do
    with true <- fetchable?(url) || {:error, :bad_url},
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url,
             headers: KickTracker.Kick.UserAgent.headers(),
             receive_timeout: 10_000,
             retry: false,
             decode_body: false,
             redirect: true,
             max_redirects: 3,
             into: &capped/2
           ),
         type when is_binary(type) <- sniff(body) || {:error, :not_an_image} do
      {:ok, type, body}
    else
      {:ok, %{body: :too_large}} -> {:error, :too_large}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _} = error -> error
    end
  end

  # The body as it arrives, dropped once it passes the limit (a huge answer
  # never fills memory).
  defp capped({:data, data}, {req, resp}) do
    body = if(is_binary(resp.body), do: resp.body, else: "") <> data

    if byte_size(body) > @max_bytes,
      do: {:halt, {req, %{resp | body: :too_large}}},
      else: {:cont, {req, %{resp | body: body}}}
  end

  @doc """
  Copies a channel's current picture, unless the copy is already of it.
  Returns `:ok`, `:unchanged`, `:no_url`, or `{:error, reason}`.
  """
  @spec refresh(integer()) :: :ok | :unchanged | :no_url | {:error, term()}
  def refresh(channel_id) do
    url = Repo.one(from c in "channels", where: c.id == ^channel_id, select: c.avatar_url)

    have =
      Repo.one(
        from a in "channel_avatars", where: a.channel_id == ^channel_id, select: a.source_url
      )

    cond do
      url == nil -> :no_url
      url == have -> :unchanged
      true -> fetch_and_store(channel_id, url)
    end
  end

  defp fetch_and_store(channel_id, url) do
    with {:ok, type, bytes} <- download(url) do
      row = %{
        channel_id: channel_id,
        source_url: url,
        content_type: type,
        data: bytes,
        sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
        fetched_at: DateTime.utc_now()
      }

      Repo.insert_all("channel_avatars", [row],
        on_conflict: {:replace, [:source_url, :content_type, :data, :sha256, :fetched_at]},
        conflict_target: [:channel_id]
      )

      :ok
    end
  end

  @doc "Channels whose picture is known but not copied (or copied from an older URL)."
  @spec stale() :: [integer()]
  def stale do
    Repo.all(
      from c in "channels",
        left_join: a in "channel_avatars",
        on: a.channel_id == c.id,
        where:
          not is_nil(c.avatar_url) and (is_nil(a.channel_id) or a.source_url != c.avatar_url),
        select: c.id
    )
  end

  @doc "A public channel's copy, for serving: `%{content_type, data, sha256}` or nil."
  @spec get(integer()) :: map() | nil
  def get(channel_id) do
    Repo.one(
      from a in "channel_avatars",
        join: c in "channels",
        on: c.id == a.channel_id,
        where: a.channel_id == ^channel_id and c.public,
        select: %{content_type: a.content_type, data: a.data, sha256: a.sha256}
    )
  end

  @doc """
  Which public channels have a copy, by id, with a short version of it
  (for URLs that change with the picture, so browsers can keep it long).
  Cached for a minute.
  """
  @spec versions() :: %{integer() => String.t()}
  def versions do
    Cache.fetch({__MODULE__, :versions}, 60, fn ->
      Repo.all(
        from a in "channel_avatars",
          join: c in "channels",
          on: c.id == a.channel_id,
          where: c.public,
          select: {a.channel_id, fragment("left(?, 12)", a.sha256)}
      )
      |> Map.new()
    end)
  end
end
