defmodule KickTracker.Workers.DeleteChannelTest do
  use KickTracker.DataCase, async: false
  use Oban.Testing, repo: KickTracker.Repo
  @moduletag :capture_log

  alias KickTracker.{Bulk, Channels, Reports}
  alias KickTracker.Workers.DeleteChannel

  @to ~U[2026-03-04 00:00:00Z]

  setup do
    scenario =
      Sim.Scenario.new(
        seed: 3,
        channels: [
          [
            slug: "gonestreamer",
            peak_viewers: 100,
            schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 20, duration_min: 60}
          ],
          [
            slug: "stayingstreamer",
            peak_viewers: 100,
            schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 18, duration_min: 60}
          ]
        ]
      )

    Bulk.run(scenario, DateTime.add(@to, -2, :day), @to)
    :ok
  end

  test "a hidden channel disappears from every public list but keeps its data" do
    gone = Channels.get_by_slug("gonestreamer")
    {:ok, _} = Channels.set_public(gone, false)

    assert Reports.channel_by_slug("gonestreamer") == nil
    assert Enum.map(Reports.channels(), & &1.slug) == ["stayingstreamer"]
    assert Reports.search("streamer") |> Enum.map(& &1.slug) == ["stayingstreamer"]

    refute Enum.any?(
             Reports.leaderboard(DateTime.add(@to, -2, :day), @to, "hours_watched"),
             &(&1.slug == "gonestreamer")
           )

    assert Reports.streams(gone) != []
  end

  test "deleting removes every row of the channel and nothing of the others" do
    gone = Channels.get_by_slug("gonestreamer")
    staying = Channels.get_by_slug("stayingstreamer")

    count = fn table, id ->
      Repo.query!("SELECT count(*) FROM #{table} WHERE channel_id = $1", [id]).rows
      |> hd()
      |> hd()
    end

    before = count.("viewer_samples", staying.id)

    assert :ok = perform_job(DeleteChannel, %{"channel_id" => gone.id})

    assert Channels.get_by_slug("gonestreamer") == nil

    for t <-
          ~w(streams viewer_samples chat_minutes follower_samples follows support_events coverage hourly_stats stream_stats) do
      assert count.(t, gone.id) == 0, t
    end

    assert count.("viewer_samples", staying.id) == before
    assert_enqueued(worker: KickTracker.Workers.SubscriptionSync)

    # Remembered, so an import can't bring it back.
    assert Repo.query!("SELECT kind, kick_user_id FROM removals").rows == [
             ["channel", gone.kick_user_id]
           ]
  end

  test "a channel being collected is stopped, and its last writes made, before anything is deleted" do
    alias KickTracker.Tracking
    alias KickTracker.Tracking.{ChannelServer, Manager}

    gone = Channels.get_by_slug("gonestreamer")
    start_supervised!({Registry, keys: :unique, name: Tracking.registry()})

    start_supervised!(
      {DynamicSupervisor, name: Tracking.ChannelsSupervisor, strategy: :one_for_one}
    )

    start_supervised!({Manager, on_change: fn -> :ok end})
    Manager.sync()
    server = ChannelServer.whereis(gone.kick_user_id)

    # Chat gathered but not yet written: its process writes it when it stops.
    send(server, {:chat, %{id: "x", sender_id: 7, username: nil, at: DateTime.utc_now()}})
    ChannelServer.info(server)

    assert :ok = perform_job(DeleteChannel, %{"channel_id" => gone.id})

    # Before, the job only broadcast `:removed` and went on deleting while
    # the process still ran: its last chat then failed to write for a
    # channel no longer there, or came after the delete.
    refute Process.alive?(server)
    assert Tracking.whereis({:channel_sup, gone.id}) == nil
    assert Channels.get_by_slug("gonestreamer") == nil

    assert Repo.query!("SELECT count(*) FROM chat_minute_users WHERE channel_id = $1", [gone.id]).rows ==
             [[0]]
  end
end
