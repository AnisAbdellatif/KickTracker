defmodule KickTracker.CorrectionsTest do
  @moduledoc "Corrections sit on top of the raw streams and change every figure built on them."

  use KickTracker.DataCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import KickTracker.Fixtures
  alias KickTracker.{Corrections, Reports, Rollups}
  alias KickTracker.Workers.Reprocess

  @t0 ~U[2026-03-02 20:00:00Z]
  defp at(min), do: DateTime.add(@t0, min * 60)

  setup do
    c = channel!(slug: "somestreamer")
    # One broadcast the sessionizer split in two by a 10-minute drop.
    a = stream!(c, at(0), at(60))
    samples!(c, a, for(m <- 0..59, do: {at(m), 100}))
    b = stream!(c, at(70), at(130))
    samples!(c, b, for(m <- 70..129, do: {at(m), 200}))
    Enum.each([a, b], &Rollups.stream_stats/1)
    {admin, _, _} = admin!()
    %{c: c, a: a, b: b, admin: admin}
  end

  test "merging shows one stream, from the first start to the last end, with figures over both",
       %{c: c, a: a, b: b, admin: admin} do
    assert {:ok, _} = Corrections.merge(a, b, "one broadcast", admin)
    assert_enqueued(worker: Reprocess, args: %{"kind" => "rollups"})

    perform_job(Reprocess, %{
      "kind" => "rollups",
      "from" => DateTime.to_iso8601(at(0)),
      "to" => DateTime.to_iso8601(at(130)),
      "stream_ids" => [a, b]
    })

    assert [%{id: ^a, ended_at: ended, peak_viewers: 200, avg_viewers: avg}] = Reports.streams(c)
    assert DateTime.compare(ended, at(130)) == :eq
    assert_in_delta avg, 150.0, 0.01
    assert Reports.stream(b).merged_into == a
    assert Reports.stream(a).stream_ids == [a, b]
    assert Reports.period(c, at(-10), at(200)).streams == 1

    assert [%{action: "correction.merge"} | _] = KickTracker.Audit.recent()
  end

  test "a merge must be into the previous stream of the same channel", %{
    c: c,
    a: a,
    b: b,
    admin: admin
  } do
    assert {:error, _} = Corrections.merge(b, a, "", admin)
    later = stream!(c, at(200), at(260))
    assert {:error, "another stream lies between them"} = Corrections.merge(a, later, "", admin)
    other = stream!(channel!(), at(300), at(310))
    assert {:error, "streams of different channels"} = Corrections.merge(later, other, "", admin)
  end

  test "an exclusion can be revoked, and the stream counts again", %{c: c, b: b, admin: admin} do
    {:ok, id} = Corrections.exclude(b, "test stream", admin)
    assert {:error, _} = Corrections.exclude(b, "again", admin)
    assert Reports.period(c, at(-10), at(200)).streams == 1

    assert :ok = Corrections.revoke(id, admin)
    assert Reports.period(c, at(-10), at(200)).streams == 2
    assert [%{revoked_at: %DateTime{}}] = Corrections.list(c.id)
  end
end
