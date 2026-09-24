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

  # A broadcast the sessionizer split in three: a, b and d.
  defp third_part(c) do
    d = stream!(c, at(140), at(200))
    samples!(c, d, for(m <- 140..199, do: {at(m), 5000}))
    Rollups.stream_stats(d)
    d
  end

  defp rollups(ids) do
    perform_job(Reprocess, %{
      "kind" => "rollups",
      "from" => DateTime.to_iso8601(at(0)),
      "to" => DateTime.to_iso8601(at(200)),
      "stream_ids" => ids
    })
  end

  defp assert_one_stream(c, a, b, d) do
    # Before, d's figures (a peak of 5000) were in no listed stream: a
    # folded in only what was merged into it directly.
    assert [%{id: ^a, peak_viewers: 5000, ended_at: ended}] = Reports.streams(c)
    assert DateTime.compare(ended, at(200)) == :eq
    assert Reports.stream(d).merged_into == a
    assert Reports.stream(b).merged_into == a
    assert Reports.stream(a).stream_ids == [a, b, d]
    assert %{peak: %{stream_id: ^a, peak_viewers: 5000}} = Reports.records(c)
    assert Reports.period(c, at(-10), at(300)).streams == 1
  end

  test "a stream split in three merges into one, merging into the first", %{
    c: c,
    a: a,
    b: b,
    admin: admin
  } do
    d = third_part(c)
    assert {:ok, _} = Corrections.merge(a, b, "", admin)
    # b is already part of a, so it no longer lies between a and d.
    assert {:ok, _} = Corrections.merge(a, d, "", admin)
    rollups([a, b, d])
    assert_one_stream(c, a, b, d)
  end

  test "merging into a stream that was itself merged goes to the root", %{
    c: c,
    a: a,
    b: b,
    admin: admin
  } do
    d = third_part(c)
    assert {:ok, _} = Corrections.merge(a, b, "", admin)
    assert {:ok, id} = Corrections.merge(b, d, "", admin)

    assert %{stream_id: ^a, other_stream_id: ^d} =
             Enum.find(Corrections.list(c.id), &(&1.id == id))

    assert {:error, "already merged"} = Corrections.merge(a, d, "", admin)
    rollups([a, b, d])
    assert_one_stream(c, a, b, d)
  end

  test "a chain merged one level at a time (older rows) still folds in every part", %{
    c: c,
    a: a,
    b: b
  } do
    d = third_part(c)

    Repo.query!("""
    INSERT INTO stream_overrides (kind, stream_id, other_stream_id, inserted_at)
    VALUES ('merge', #{a}, #{b}, now()), ('merge', #{b}, #{d}, now())
    """)

    rollups([a, b, d])
    assert_one_stream(c, a, b, d)
  end

  test "excluding a merged stream leaves out every part, in hourly figures too", %{
    c: c,
    a: a,
    b: b,
    admin: admin
  } do
    assert {:ok, _} = Corrections.merge(a, b, "", admin)
    assert {:ok, _} = Corrections.exclude(a, "rebroadcast", admin)
    rollups([a, b])

    # Before, b stayed in hourly figures: only a was in excluded_streams.
    assert Reports.period(c, at(-10), at(200)).hours_watched == nil
    assert Reports.period(c, at(-10), at(200)).streams == 0
    assert [%{id: ^a, excluded?: true}] = Reports.streams(c)
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
