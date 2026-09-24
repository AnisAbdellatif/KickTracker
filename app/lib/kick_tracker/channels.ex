defmodule KickTracker.Channels do
  @moduledoc """
  The tracked channels. Adding or pausing one is a row change plus a
  `"channels:changed"` broadcast (project.md §10): the collector starts or
  stops the channel's processes and syncs its webhook subscriptions, with
  no redeploy.
  """

  import Ecto.Query

  alias KickTracker.Channels.Channel
  alias KickTracker.Kick.API
  alias KickTracker.Repo

  @topic "channels:changed"

  @doc "The PubSub topic announcing a change to the tracked set."
  def topic, do: @topic

  @spec list_active() :: [Channel.t()]
  def list_active, do: Repo.all(from c in Channel, where: c.active, order_by: c.id)

  @spec get!(integer()) :: Channel.t()
  def get!(id), do: Repo.get!(Channel, id)

  @spec get_by_kick_user_id(integer()) :: Channel.t() | nil
  def get_by_kick_user_id(user_id), do: Repo.get_by(Channel, kick_user_id: user_id)

  @spec list_all() :: [Channel.t()]
  def list_all, do: Repo.all(from c in Channel, order_by: [desc: c.active, asc: c.slug])

  @spec get_by_slug(String.t()) :: Channel.t() | nil
  def get_by_slug(slug),
    do: Repo.one(from c in Channel, where: fragment("lower(?)", c.slug) == ^String.downcase(slug))

  @doc """
  Looks a slug up on Kick before it is added (project.md §13.8): its ids,
  live status, category, title and language, a suggested timezone, and the
  channel if we already track it.
  """
  @spec preview(String.t()) :: {:ok, map()} | {:error, term()}
  def preview(slug) do
    slug = slug |> String.trim() |> String.trim_leading("/") |> String.downcase()

    with :ok <- valid_slug(slug),
         {:ok, %{"broadcaster_user_id" => user_id, "slug" => kick_slug} = data} <-
           API.channel_by_slug(slug) do
      stream = data["stream"] || %{}
      language = stream["language"]

      {:ok,
       %{
         slug: kick_slug,
         kick_user_id: user_id,
         live?: stream["is_live"] == true,
         viewers: stream["viewer_count"],
         category: get_in(data, ["category", "name"]),
         title: data["stream_title"],
         language: language,
         timezone: suggested_timezone(language),
         existing: get_by_kick_user_id(user_id)
       }}
    else
      {:ok, _unexpected} -> {:error, :unexpected_response}
      error -> error
    end
  end

  defp valid_slug(slug) do
    if Regex.match?(~r/^[a-z0-9_-]{1,64}$/, slug), do: :ok, else: {:error, :not_found}
  end

  # A first guess from the stream's language, always shown for editing. Daily
  # and weekday figures use it (§12.2), so the admin should check it.
  @timezones %{
    "ar" => "Africa/Tunis",
    "fr" => "Europe/Paris",
    "de" => "Europe/Berlin",
    "es" => "Europe/Madrid",
    "it" => "Europe/Rome",
    "pt" => "America/Sao_Paulo",
    "tr" => "Europe/Istanbul",
    "ru" => "Europe/Moscow",
    "pl" => "Europe/Warsaw",
    "nl" => "Europe/Amsterdam",
    "ja" => "Asia/Tokyo",
    "ko" => "Asia/Seoul"
  }

  @doc "The timezone suggested for a stream language; UTC when unknown."
  @spec suggested_timezone(String.t() | nil) :: String.t()
  def suggested_timezone(language), do: Map.get(@timezones, language, "Etc/UTC")

  @doc "Whether PostgreSQL knows this timezone (it applies them at read time)."
  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(tz) when is_binary(tz) do
    %{rows: [[known?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)", [tz])

    known?
  end

  def valid_timezone?(_), do: false

  @doc "Every timezone name PostgreSQL knows, for the timezone picker."
  @spec timezones() :: [String.t()]
  def timezones do
    Repo.query!(
      "SELECT name FROM pg_timezone_names WHERE name !~ '^(posix|Etc/GMT[+-])' ORDER BY name"
    ).rows
    |> List.flatten()
  end

  @doc """
  Starts tracking a channel by its slug: looks it up on Kick (one slug at a
  time, since an unknown slug fails a whole batch), then inserts it, or
  reactivates it if it was tracked before. `timezone:` sets its timezone.
  """
  @spec add(String.t(), keyword()) :: {:ok, Channel.t()} | {:error, term()}
  def add(slug, opts \\ []) do
    timezone = opts[:timezone]

    with :ok <-
           if(timezone && not valid_timezone?(timezone), do: {:error, :bad_timezone}, else: :ok),
         {:ok, %{"broadcaster_user_id" => user_id, "slug" => kick_slug}} <-
           API.channel_by_slug(slug) do
      now = DateTime.utc_now()
      tz = if timezone, do: [timezone: timezone], else: []

      result =
        Repo.transaction(fn ->
          channel =
            case get_by_kick_user_id(user_id) do
              nil ->
                Repo.insert!(
                  struct(Channel, [kick_user_id: user_id, slug: kick_slug, active: true] ++ tz)
                )

              channel ->
                channel |> Ecto.Changeset.change([active: true] ++ tz) |> Repo.update!()
            end

          record_slug(channel, kick_slug, now)
          Repo.get!(Channel, channel.id)
        end)

      with {:ok, channel} <- result do
        broadcast({:added, channel.id})
        # A first follower reading, which also learns the chatroom id.
        KickTracker.Workers.FollowerPoll.enqueue(channel.id, :added)
        {:ok, channel}
      end
    else
      {:ok, _unexpected} -> {:error, :unexpected_response}
      error -> error
    end
  end

  @doc "Channels with an open stream, and when it started."
  @spec open_streams() :: %{integer() => DateTime.t()}
  def open_streams do
    Repo.all(from s in "streams", where: is_nil(s.ended_at), select: {s.channel_id, s.started_at})
    |> Map.new()
  end

  @doc "Changes the timezone daily and weekday figures are read in."
  @spec set_timezone(Channel.t(), String.t()) :: {:ok, Channel.t()} | {:error, :bad_timezone}
  def set_timezone(%Channel{} = channel, timezone) do
    if valid_timezone?(timezone),
      do: channel |> Ecto.Changeset.change(timezone: timezone) |> Repo.update(),
      else: {:error, :bad_timezone}
  end

  @doc "Stops or resumes tracking. History is kept either way."
  @spec set_active(Channel.t(), boolean()) :: {:ok, Channel.t()}
  def set_active(%Channel{} = channel, active?) do
    {:ok, channel} = channel |> Ecto.Changeset.change(active: active?) |> Repo.update()
    broadcast({if(active?, do: :added, else: :removed), channel.id})
    {:ok, channel}
  end

  @doc """
  Records the slug Kick reports now. A rename closes the previous slug's
  period in `channel_slugs` and updates the channel.
  """
  @spec observe_slug(Channel.t(), String.t(), DateTime.t()) :: Channel.t()
  def observe_slug(%Channel{slug: slug} = channel, slug, _at), do: channel

  def observe_slug(%Channel{} = channel, slug, at) do
    Repo.transaction(fn ->
      record_slug(channel, slug, at)
      channel |> Ecto.Changeset.change(slug: slug) |> Repo.update!()
    end)
    |> elem(1)
  end

  @doc "Stores Kick's other ids for the channel (for chat), when learnt."
  @spec put_ids(Channel.t(), integer() | nil, integer() | nil) :: Channel.t()
  def put_ids(%Channel{} = channel, kick_channel_id, chatroom_id) do
    changes =
      [kick_channel_id: kick_channel_id, chatroom_id: chatroom_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    channel |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  @doc """
  Tells the channel's running processes about a changed row (a rename, a
  chatroom id learnt), on the channel's own topic.
  """
  @spec announce(Channel.t()) :: :ok
  def announce(%Channel{} = channel) do
    Phoenix.PubSub.broadcast(KickTracker.PubSub, "channel_row:#{channel.id}", {:channel, channel})
  end

  defp record_slug(channel, slug, at) do
    current =
      Repo.one(
        from s in "channel_slugs",
          where: s.channel_id == ^channel.id and is_nil(s.seen_to),
          select: %{id: s.id, slug: s.slug}
      )

    case current do
      %{slug: ^slug} ->
        :ok

      other ->
        if other,
          do:
            Repo.update_all(from(s in "channel_slugs", where: s.id == ^other.id),
              set: [seen_to: at]
            )

        Repo.insert_all("channel_slugs", [%{channel_id: channel.id, slug: slug, seen_from: at}])
    end
  end

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(KickTracker.PubSub, @topic, message)
end
