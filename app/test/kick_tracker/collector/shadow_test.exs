defmodule KickTracker.Collector.ShadowTest do
  @moduledoc """
  The shadow collector and the primary side, each with its own database
  (the other one is `KickTracker.OtherSide`, over a real connection):
  the primary fills an outage from the shadow's data, once, without
  doubling anything; the shadow follows the primary's channel list and
  removals, and says when it can't reach it.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KickTracker.Fixtures
  alias KickTracker.Collector.Remote
  alias KickTracker.OtherSide
  alias KickTracker.Workers.{Backfill, ShadowSync}

  setup do
    OtherSide.reset!()
    :ok
  end

  defp minute(t), do: t |> DateTime.truncate(:second) |> Map.put(:second, 0)

  describe "backfill on the primary side" do
    setup do
      # An hour-long stream two hours ago. We polled its first 10 minutes
      # and its last 20, and were down in between; the shadow saw it all.
      t0 = minute(DateTime.add(DateTime.utc_now(), -2 * 3600))
      at = fn m -> DateTime.add(t0, m * 60) end
      c = channel!(kick_user_id: 7_000_001)
      s = stream!(c, t0)
      ours = Enum.to_list(0..9) ++ Enum.to_list(40..59)
      samples!(c, s, for(m <- ours, do: {at.(m), 100}))
      covered!(c, "api", at.(0), at.(9))
      covered!(c, "api", at.(40), at.(59))

      # Chat: we have minute 5 and minute 40; the shadow has 5 and 20..24.
      Repo.insert_all("chat_minutes", [
        %{channel_id: c.id, minute: at.(5), stream_id: s, messages: 2, chatters: 1},
        %{channel_id: c.id, minute: at.(40), stream_id: s, messages: 1, chatters: 1}
      ])

      covered!(c, "chat", at.(0), at.(9))
      covered!(c, "chat", at.(40), at.(59))

      [[sc]] =
        OtherSide.query!(
          "INSERT INTO channels (kick_user_id, slug, timezone, tracked_since, active, public, inserted_at, updated_at) VALUES (7000001, 'somestreamer', 'Etc/UTC', now(), true, true, now(), now()) RETURNING id"
        )

      [[ss]] =
        OtherSide.query!(
          "INSERT INTO streams (channel_id, started_at) VALUES ($1, $2) RETURNING id",
          [sc, t0]
        )

      for m <- 0..59 do
        OtherSide.query!(
          "INSERT INTO viewer_samples (channel_id, observed_at, stream_id, viewers) VALUES ($1, $2, $3, 500)",
          [sc, at.(m), ss]
        )
      end

      for m <- [5, 20, 21, 22, 23, 24] do
        OtherSide.query!(
          "INSERT INTO chat_minutes (channel_id, minute, stream_id, messages, chatters) VALUES ($1, $2, $3, 3, 1)",
          [sc, at.(m), ss]
        )

        OtherSide.query!(
          "INSERT INTO chat_minute_users (channel_id, minute, user_id, messages) VALUES ($1, $2, 424242, 3)",
          [sc, at.(m)]
        )
      end

      OtherSide.query!(
        "INSERT INTO kick_users (id, username, seen_at) VALUES (424242, 'someone', now())"
      )

      for source <- ["api", "chat"] do
        OtherSide.query!(
          "INSERT INTO coverage (channel_id, source, from_at, to_at, ok) VALUES ($1, $2, $3, $4, true)",
          [sc, source, at.(0), at.(59)]
        )
      end

      OtherSide.query!(
        "INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status) VALUES ('shadow-a', 'leader', 4, now(), now(), '{}')"
      )

      %{channel: c, at: at}
    end

    defp backfill do
      {:ok, summary} = Remote.with_conn(OtherSide.url(), &Backfill.run/1)
      summary
    end

    test "the outage is filled from the shadow; what we had stays ours", %{channel: c, at: at} do
      assert %{filled: 2} = backfill()

      samples = rows("viewer_samples", ["observed_at"])
      assert length(samples) == 60
      # Ours kept their values; the gap came from the shadow.
      viewers = Map.new(samples, &{DateTime.to_unix(&1.observed_at), &1.viewers})
      assert viewers[DateTime.to_unix(at.(5))] == 100
      assert viewers[DateTime.to_unix(at.(20))] == 500
      assert [%{channel_id: id}] = rows("streams", ["id"])
      assert id == c.id

      # Chat: only the whole minutes we had nothing for; minute 5 untouched.
      chat =
        rows("chat_minutes", ["minute"]) |> Map.new(&{DateTime.to_unix(&1.minute), &1.messages})

      assert chat[DateTime.to_unix(at.(5))] == 2
      for m <- 20..24, do: assert(chat[DateTime.to_unix(at.(m))] == 3)
      assert map_size(chat) == 7

      assert rows("coverage", ["id"]) |> Enum.filter(&(&1.collector == "shadow")) |> length() == 2

      # The shadow as seen from here.
      assert [%{state: "shadow", epoch: 4}] =
               rows("collector_nodes", ["id"]) |> Enum.filter(&(&1.id == "shadow"))
    end

    test "running again fills nothing and doubles nothing" do
      backfill()
      before = {rows("viewer_samples", ["observed_at"]), rows("chat_minute_users", ["minute"])}
      assert %{filled: 0} = backfill()

      assert {rows("viewer_samples", ["observed_at"]), rows("chat_minute_users", ["minute"])} ==
               before
    end

    test "a user removed here isn't brought back from the shadow", %{at: at} do
      KickTracker.Removals.record(:user, 424_242)
      backfill()

      assert rows("chat_minute_users", ["minute"])
             |> Enum.filter(&(DateTime.compare(&1.minute, at.(20)) == :eq)) == []

      assert Repo.query!("SELECT 1 FROM kick_users WHERE id = 424242").rows == []
    end
  end

  describe "the shadow's sync with the primary side" do
    setup do
      start_supervised!(KickTracker.Collector.Journal)

      OtherSide.query!("""
      INSERT INTO channels (kick_user_id, slug, timezone, chatroom_id, tracked_since, active, public, inserted_at, updated_at)
      VALUES (7000002, 'somestreamer', 'Africa/Tunis', 55, now(), true, true, now(), now()),
             (7000003, 'otherstreamer', 'Etc/UTC', NULL, now(), false, true, now(), now())
      """)

      :ok
    end

    defp sync,
      do:
        OtherSide.url()
        |> Remote.with_conn(&ShadowSync.read_main/1)
        |> ShadowSync.handle(DateTime.utc_now())

    test "tracks what the primary tracks, and stops what it stopped" do
      paused_there = channel!(kick_user_id: 7_000_003)
      :ok = sync()

      assert %{slug: "somestreamer", timezone: "Africa/Tunis", chatroom_id: 55, active: true} =
               KickTracker.Channels.get_by_kick_user_id(7_000_002)

      refute KickTracker.Channels.get!(paused_there.id).active
    end

    test "carries out the primary's removals" do
      c = channel!(kick_user_id: 7_000_004)

      OtherSide.query!(
        "INSERT INTO removals VALUES ('channel', 7000004, now()), ('user', 424242, now())"
      )

      :ok = sync()

      assert KickTracker.Channels.get_by_kick_user_id(c.kick_user_id) == nil

      assert Repo.query!("SELECT kind, kick_user_id FROM removals ORDER BY kind").rows ==
               [["channel", 7_000_004], ["user", 424_242]]
    end

    test "the primary unreachable for 5 minutes is notified once, and again when it's back" do
      down = {:error, :econnrefused}
      t = DateTime.utc_now()

      log =
        capture_log(fn ->
          ShadowSync.handle(down, t)
          ShadowSync.handle(down, DateTime.add(t, 120))
          ShadowSync.handle(down, DateTime.add(t, 360))
          ShadowSync.handle(down, DateTime.add(t, 420))
        end)

      assert length(Regex.scan(~r/can't reach the primary side/, log)) == 1

      assert capture_log(fn -> :ok = sync() end) =~ "answers the shadow collector again"
    end
  end
end
