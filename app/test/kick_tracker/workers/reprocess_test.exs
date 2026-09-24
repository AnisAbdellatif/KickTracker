defmodule KickTracker.Workers.ReprocessTest do
  use KickTracker.DataCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import KickTracker.Fixtures
  alias KickTracker.{Events, TestKick}
  alias KickTracker.Events.Envelope
  alias KickTracker.Workers.Reprocess

  test "replaying stored events restores facts that are missing, and duplicates nothing" do
    c = channel!()
    b = TestKick.user(c.kick_user_id, "somestreamer")

    {:ok, e} =
      TestKick.message("channel.followed", %{
        "broadcaster" => b,
        "follower" => TestKick.user(5, "fan")
      })
      |> Envelope.decode()

    {:ok, _} = Events.ingest([e])

    # Lost somehow (a handler bug fixed since, say).
    Repo.query!("DELETE FROM follows")

    range = %{
      "from" => DateTime.to_iso8601(DateTime.add(e.occurred_at, -60)),
      "to" => DateTime.to_iso8601(DateTime.add(e.occurred_at, 60))
    }

    assert :ok =
             perform_job(Reprocess, Map.merge(range, %{"kind" => "replay", "channel_id" => c.id}))

    assert :ok = perform_job(Reprocess, Map.merge(range, %{"kind" => "replay"}))
    assert [%{user_id: 5}] = rows("follows", ["message_id"])
  end

  test "recomputing rollups fills the stream's figures" do
    c = channel!()
    s = stream!(c, ~U[2026-03-02 20:00:00Z], ~U[2026-03-02 21:00:00Z])
    samples!(c, s, [{~U[2026-03-02 20:10:00Z], 50}])

    assert :ok =
             perform_job(Reprocess, %{
               "kind" => "rollups",
               "from" => "2026-03-02T19:00:00Z",
               "to" => "2026-03-02T22:00:00Z"
             })

    assert [%{peak_viewers: 50}] = rows("stream_stats", ["stream_id"])
    assert [%{peak_viewers: 50}] = rows("hourly_stats", ["hour"])
  end
end
