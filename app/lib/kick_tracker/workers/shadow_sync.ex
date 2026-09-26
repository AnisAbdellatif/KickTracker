defmodule KickTracker.Workers.ShadowSync do
  @moduledoc """
  The shadow collector's link to the primary side (project.md §10.5), run
  every minute on the shadow:

    * **the channel list**: the primary's active channels, by Kick id, are
      tracked here too (slug, timezone and Kick's other ids with them);
      channels no longer active there stop here. When the primary side
      can't be reached, the shadow keeps its last list and keeps
      collecting: that is when it matters;
    * **removal requests**: carried out here too, so a person or channel
      removed on the primary side is removed from the shadow's copy;
    * **the primary side unreachable** for 5 minutes is notified from here
      (its own alerts may be down with it), and notified again when it is
      back; the shadow's `HEARTBEAT_URL` is pinged every run.

  `%{"kind" => "prune"}` (daily): the shadow only needs recent data (the
  primary side backfills from the last `BACKFILL_DAYS`); what is older
  than `SHADOW_KEEP_DAYS` (30) is dropped.
  """

  use Oban.Worker, queue: :kick, max_attempts: 1, unique: [period: 50]

  require Logger

  alias KickTracker.{Channels, Collector, Privacy, Removals, Repo}
  alias KickTracker.Alerts.Notifier
  alias KickTracker.Channels.Channel
  alias KickTracker.Collector.{Journal, Remote}

  @down_after_s 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "prune"}}) do
    prune(Collector.config(:shadow_keep_days, 30))
    :ok
  end

  def perform(_job) do
    case Collector.config(:main_database_url) do
      nil -> :ok
      url -> url |> Remote.with_conn(&read_main/1) |> handle(DateTime.utc_now())
    end

    Notifier.heartbeat()
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @doc false
  # Public for tests: what the primary side says, applied here.
  def read_main(main) do
    %{
      channels:
        main.(
          "SELECT kick_user_id, slug, timezone, kick_channel_id, chatroom_id FROM channels WHERE active",
          []
        ),
      removals: main.("SELECT kind, kick_user_id FROM removals", [])
    }
  end

  @doc false
  def handle({:ok, main}, _now) do
    apply_removals(main.removals)
    sync_channels(main.channels)

    case Journal.get(:main_down) do
      {_since, true} ->
        Notifier.send("✅ the primary side answers the shadow collector again", :low)

      _ ->
        :ok
    end

    Journal.put(:main_down, nil)
    :ok
  end

  def handle({:error, reason}, now) do
    Logger.warning("shadow: the primary side can't be read: #{inspect(reason, limit: 5)}")

    case Journal.get(:main_down) do
      nil ->
        Journal.put(:main_down, {now, false})

      {since, false} ->
        if DateTime.diff(now, since) >= @down_after_s do
          Notifier.send(
            "🔴 the shadow collector can't reach the primary side (since #{Calendar.strftime(since, "%H:%M")} UTC); it keeps collecting",
            :high
          )

          Journal.put(:main_down, {since, true})
        end

      {_since, true} ->
        :ok
    end

    :ok
  end

  # --- the channel list ----------------------------------------------------------

  defp sync_channels(rows) do
    local = Repo.all(Channel) |> Map.new(&{&1.kick_user_id, &1})
    wanted = MapSet.new(rows, &hd/1)

    for row <- rows, do: sync_one(row, local)

    for {kick_user_id, channel} <- local,
        channel.active,
        not MapSet.member?(wanted, kick_user_id),
        do: Channels.set_active(channel, false)

    :ok
  end

  # One of the primary's active channels, here: created, or brought in line.
  defp sync_one([kick_user_id, slug, timezone, kick_channel_id, chatroom_id], local) do
    fields = [slug: slug, timezone: timezone, active: true]

    ids =
      Enum.reject(
        [kick_channel_id: kick_channel_id, chatroom_id: chatroom_id],
        &is_nil(elem(&1, 1))
      )

    case local[kick_user_id] do
      nil ->
        channel = Repo.insert!(struct(Channel, [kick_user_id: kick_user_id] ++ fields ++ ids))
        Channels.set_active(channel, true)

      channel ->
        update(channel, Enum.reject(fields ++ ids, fn {k, v} -> Map.get(channel, k) == v end))
    end
  end

  defp update(_channel, []), do: :ok

  defp update(channel, changes) do
    updated = channel |> Ecto.Changeset.change(changes) |> Repo.update!()
    if not channel.active, do: Channels.set_active(updated, true)
    Channels.announce(updated)
  end

  # --- removals ------------------------------------------------------------------

  defp apply_removals(rows) do
    done =
      Repo.query!("SELECT kind, kick_user_id FROM removals").rows
      |> MapSet.new(&List.to_tuple/1)

    for [kind, kick_user_id] <- rows, not MapSet.member?(done, {kind, kick_user_id}) do
      case kind do
        "user" ->
          Privacy.delete(kick_user_id)

        "channel" ->
          case Channels.get_by_kick_user_id(kick_user_id) do
            nil ->
              Removals.record(:channel, kick_user_id)

            channel ->
              :ok =
                KickTracker.Workers.DeleteChannel.perform(%Oban.Job{
                  args: %{"channel_id" => channel.id}
                })
          end
      end
    end

    :ok
  end

  # --- pruning -------------------------------------------------------------------

  # sobelow_skip ["SQL.Query"]
  defp prune(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    for table <-
          ~w(viewer_samples subscriber_samples follower_samples chat_minutes chat_minute_users) do
      Repo.query!("SELECT drop_chunks('#{table}', older_than => $1::timestamptz)", [cutoff])
    end

    Repo.query!("DELETE FROM coverage WHERE to_at < $1", [cutoff])

    old_streams =
      "SELECT id FROM streams WHERE ended_at < $1 AND NOT EXISTS (SELECT 1 FROM viewer_samples v WHERE v.stream_id = streams.id)"

    for table <- ~w(stream_changes chat_stream_users stream_stats stream_overrides viewer_flags) do
      Repo.query!("DELETE FROM #{table} WHERE stream_id IN (#{old_streams})", [cutoff])
    end

    Repo.query!(
      "DELETE FROM streams WHERE id IN (#{old_streams}) AND NOT EXISTS (SELECT 1 FROM chat_minutes m WHERE m.stream_id = streams.id)",
      [cutoff]
    )

    Logger.info("shadow: pruned data older than #{days} days")
  end
end
