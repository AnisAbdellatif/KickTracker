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

  @doc """
  Starts tracking a channel by its slug: looks it up on Kick (one slug at a
  time, since an unknown slug fails a whole batch), then inserts it, or
  reactivates it if it was tracked before.
  """
  @spec add(String.t()) :: {:ok, Channel.t()} | {:error, term()}
  def add(slug) do
    with {:ok, %{"broadcaster_user_id" => user_id, "slug" => kick_slug}} <-
           API.channel_by_slug(slug) do
      now = DateTime.utc_now()

      result =
        Repo.transaction(fn ->
          channel =
            case get_by_kick_user_id(user_id) do
              nil ->
                Repo.insert!(%Channel{kick_user_id: user_id, slug: kick_slug, active: true})

              channel ->
                channel |> Ecto.Changeset.change(active: true) |> Repo.update!()
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
