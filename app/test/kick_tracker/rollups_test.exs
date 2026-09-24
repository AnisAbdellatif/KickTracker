defmodule KickTracker.RollupsTest do
  @moduledoc "The derived tables agree with the pure formulas and with each other."

  # Not async: writes hypertables (see StatsTest).
  use KickTracker.DataCase, async: false
  use ExUnitProperties

  import KickTracker.Fixtures
  alias KickTracker.{Metrics, Rollups, Stats}

  @s ~U[2026-01-05 20:10:00.000000Z]
  defp at(s), do: DateTime.add(@s, s)

  defp stream_with_samples(c, started_at, samples, ended_at \\ nil) do
    id =
      if ended_at,
        do: Stats.apply_stream(c.id, {:close, started_at, ended_at, :event}),
        else: Stats.apply_stream(c.id, {:open, started_at})

    rows =
      for {t, v} <- samples,
          do: %{channel_id: c.id, observed_at: t, stream_id: id, viewers: v, category_id: nil}

    Stats.insert_samples("viewer_samples", rows)

    id
  end

  test "a glitch reading is flagged and left out of peaks, in the stream and the hour" do
    c = channel!()
    samples = for {v, i} <- Enum.with_index([500, 510, 9000, 505, 498]), do: {at(60 + i * 60), v}
    id = stream_with_samples(c, at(0), samples, at(600))

    Rollups.hourly(at(0), at(600))
    Rollups.stream_stats(id)

    assert [%{reason: "spike"}] = rows("viewer_flags", ["observed_at"])
    assert [%{peak_viewers: 510}] = rows("stream_stats", ["stream_id"])
    assert [%{peak_viewers: 510}] = rows("hourly_stats", ["hour"])
    # The reading itself is untouched.
    assert Enum.any?(rows("viewer_samples", ["observed_at"]), &(&1.viewers == 9000))
  end

  test "new chatters are those with no earlier stream in the channel" do
    c = channel!()
    other = channel!()
    s1 = stream_with_samples(c, at(0), [], at(3600))
    s2 = stream_with_samples(c, at(86_400), [], at(90_000))
    # Chatting elsewhere doesn't make someone a returning chatter here.
    o1 = stream_with_samples(other, at(-3600), [], at(-60))

    rows = [{s1, 1}, {s1, 2}, {s2, 2}, {s2, 3}, {o1, 3}]

    Repo.insert_all(
      "chat_stream_users",
      for(
        {sid, u} <- rows,
        do: %{stream_id: sid, user_id: u, messages: 1, first_at: at(0), last_at: at(0)}
      )
    )

    Enum.each([s1, s2], &Rollups.stream_stats/1)

    assert [%{stream_id: ^s1, new_chatters: 2}, %{stream_id: ^s2, new_chatters: 1}] =
             rows("stream_stats", ["stream_id"]) |> Enum.filter(&(&1.channel_id == c.id))
  end

  test "a stream's figures, from every raw table" do
    c = channel!()
    samples = [{at(60), 100}, {at(120), 300}, {at(250), 200}]
    id = stream_with_samples(c, @s, samples, at(3600))
    # We were receiving webhooks throughout.
    covered!(c, "ingress", at(-60), at(3600))

    Stats.insert_samples("follower_samples", [
      %{channel_id: c.id, observed_at: at(20), followers: 1000},
      %{channel_id: c.id, observed_at: at(3660), followers: 1012}
    ])

    Repo.insert_all("follows", [
      %{message_id: "f1", channel_id: c.id, occurred_at: at(100), user_id: 1},
      # Before the stream: not counted for it.
      %{message_id: "f2", channel_id: c.id, occurred_at: at(-100), user_id: 2}
    ])

    Repo.insert_all("support_events", [
      %{
        message_id: "s1",
        channel_id: c.id,
        occurred_at: at(200),
        kind: "sub",
        quantity: 1,
        payload: %{}
      },
      %{
        message_id: "s2",
        channel_id: c.id,
        occurred_at: at(300),
        kind: "gift",
        quantity: 5,
        payload: %{}
      },
      %{
        message_id: "s3",
        channel_id: c.id,
        occurred_at: at(400),
        kind: "kicks",
        quantity: 100,
        payload: %{}
      }
    ])

    Stats.write_chat(c.id, [
      %{
        minute: DateTime.add(@s, 60),
        stream_id: id,
        users: %{
          1 => %{messages: 3, first_at: at(61), last_at: at(90)},
          2 => %{messages: 1, first_at: at(70), last_at: at(70)}
        }
      }
    ])

    :ok = Rollups.stream_stats(id)
    [row] = rows("stream_stats", ["stream_id"])

    assert %{
             airtime_s: 3600,
             samples: 3,
             avg_viewers: 200.0,
             peak_viewers: 300,
             followers_start: 1000,
             followers_end: 1012,
             follower_gain: 12,
             follows: 1,
             subs: 1,
             resubs: 0,
             gifted_subs: 5,
             kicks: 100,
             unique_chatters: 2,
             messages: 4
           } = row

    assert_in_delta row.hours_watched, Metrics.hours_watched(@s, samples), 1.0e-9
  end

  test "a live stream with no data yet: nothing is invented" do
    c = channel!()
    id = stream_with_samples(c, @s, [])
    :ok = Rollups.stream_stats(id)

    assert [
             %{
               samples: 0,
               avg_viewers: nil,
               peak_viewers: nil,
               airtime_s: nil,
               hours_watched: nil,
               follower_gain: nil
             }
           ] =
             rows("stream_stats", ["stream_id"])
  end

  property "hourly hours watched add up to the stream's, and match the pure formula" do
    check all(
            gaps <- list_of(integer(20..200), min_length: 1, max_length: 150),
            viewers <- list_of(integer(0..10_000), length: length(gaps)),
            max_runs: 25
          ) do
      Repo.query!("DELETE FROM viewer_samples")
      Repo.query!("DELETE FROM hourly_stats")
      Repo.query!("DELETE FROM streams")

      c = channel!()
      times = Enum.scan(gaps, &(&1 + &2))
      samples = Enum.zip(Enum.map(times, &at/1), viewers)
      stream_with_samples(c, @s, samples)

      # Recompute in two pieces, to check the edge between ranges.
      last = samples |> List.last() |> elem(0)
      middle = DateTime.add(@s, div(DateTime.diff(last, @s), 2))
      Rollups.hourly(@s, middle)
      Rollups.hourly(middle, last)

      hourly = rows("hourly_stats", ["hour"])

      assert_in_delta Enum.sum_by(hourly, &(&1.hours_watched || 0)),
                      Metrics.hours_watched(@s, samples),
                      1.0e-6

      assert Enum.sum_by(hourly, & &1.samples) == length(samples)
    end
  end

  test "hourly rows: chat, followers, follows and support by UTC hour; an empty hour has no row" do
    c = channel!()
    stream_with_samples(c, @s, [{at(60), 10}])

    Stats.insert_samples("follower_samples", [
      %{channel_id: c.id, observed_at: at(100), followers: 5},
      %{channel_id: c.id, observed_at: at(200), followers: 7}
    ])

    Repo.insert_all("follows", [
      %{message_id: "f", channel_id: c.id, occurred_at: at(7200 + 5), user_id: 1}
    ])

    Rollups.hourly(at(0), at(3 * 3600))

    assert [
             %{hour: h1, samples: 1, followers_last: 7},
             %{hour: h3, follows: 1, samples: 0, hours_watched: nil, avg_viewers: nil}
           ] = rows("hourly_stats", ["hour"])

    assert h1 == ~U[2026-01-05 20:00:00.000000Z]
    assert h3 == ~U[2026-01-05 22:00:00.000000Z]
  end

  describe "a merged stream" do
    setup do
      c = channel!()
      # One broadcast split in two by a 10-minute drop.
      a_samples = for m <- 1..59, do: {at(m * 60), 100}
      b_samples = for m <- 70..129, do: {at(m * 60), 200}
      a = stream_with_samples(c, at(0), a_samples, at(3600))
      b = stream_with_samples(c, at(69 * 60 + 30), b_samples, at(130 * 60))

      Repo.query!(
        "INSERT INTO stream_overrides (kind, stream_id, other_stream_id, inserted_at) VALUES ('merge', $1, $2, now())",
        [a, b]
      )

      %{c: c, a: a, b: b, samples: a_samples ++ b_samples}
    end

    test "airtime leaves out the drop, and hours watched add up to the hours'", %{
      a: a,
      samples: samples
    } do
      Rollups.hourly(at(0), at(130 * 60))
      :ok = Rollups.stream_stats(a)
      [row] = rows("stream_stats", ["stream_id"]) |> Enum.filter(&(&1.stream_id == a))

      # Before: from a's start to b's end (7800s, the 9.5-minute drop
      # included), and b's first sample weighted across the drop from a's
      # last one (75s) rather than from b's own start (30s).
      before_airtime = 130 * 60
      before_hw = Metrics.hours_watched(at(0), samples)

      assert row.airtime_s == 3600 + (130 * 60 - (69 * 60 + 30))
      assert row.airtime_s < before_airtime

      hourly = rows("hourly_stats", ["hour"]) |> Enum.sum_by(&(&1.hours_watched || 0))
      assert_in_delta row.hours_watched, hourly, 1.0e-6
      assert_in_delta before_hw - row.hours_watched, 200 * (75 - 30) / 3600, 1.0e-6
    end
  end

  test "follows and support are unknown, not 0, where the ingress didn't cover the stream" do
    c = channel!()
    id = stream_with_samples(c, at(0), [{at(60), 10}], at(3600))

    Repo.insert_all("follows", [
      %{message_id: "f", channel_id: c.id, occurred_at: at(100), user_id: 1}
    ])

    # No ingress coverage: before, follows 1 and subs 0 as if known.
    :ok = Rollups.stream_stats(id)

    assert [%{follows: nil, subs: nil, resubs: nil, gifted_subs: nil, kicks: nil}] =
             rows("stream_stats", ["stream_id"])

    # Covered for only half of it: still unknown.
    covered!(c, "ingress", at(0), at(1800))
    :ok = Rollups.stream_stats(id)
    assert [%{follows: nil}] = rows("stream_stats", ["stream_id"])

    # Covered throughout: counted, and 0 where nothing happened.
    covered!(c, "ingress", at(1800), at(3600))
    :ok = Rollups.stream_stats(id)

    assert [%{follows: 1, subs: 0, gifted_subs: 0, kicks: 0}] =
             rows("stream_stats", ["stream_id"])
  end

  test "an excluded earlier stream doesn't make a chatter returning" do
    c = channel!()
    s1 = stream_with_samples(c, at(0), [], at(3600))
    s2 = stream_with_samples(c, at(86_400), [], at(90_000))

    Repo.insert_all(
      "chat_stream_users",
      for(
        {sid, u} <- [{s1, 1}, {s2, 1}, {s2, 2}],
        do: %{stream_id: sid, user_id: u, messages: 1, first_at: at(0), last_at: at(0)}
      )
    )

    Repo.query!(
      "INSERT INTO stream_overrides (kind, stream_id, inserted_at) VALUES ('exclude', $1, now())",
      [s1]
    )

    :ok = Rollups.stream_stats(s2)
    assert [%{new_chatters: 2}] = rows("stream_stats", ["stream_id"])
  end

  test "a full rebuild starts at the earliest raw fact, not the first stream" do
    c = channel!()
    stream_with_samples(c, at(86_400), [{at(86_460), 10}], at(90_000))

    Repo.insert_all("follows", [
      %{message_id: "early", channel_id: c.id, occurred_at: at(0), user_id: 1}
    ])

    assert DateTime.compare(Rollups.earliest_fact(), at(0)) == :eq
  end

  describe "concurrent rebuilds" do
    # Real connections outside the sandbox: the sandbox would run the two
    # rebuilds one after the other on its one connection.
    @far ~U[2031-01-06 10:00:00.000000Z]

    setup do
      unboxed = &Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &1)

      c =
        unboxed.(fn ->
          c = channel!()
          samples = for m <- 1..179, do: {DateTime.add(@far, m * 60), 100 + rem(m, 7)}
          stream_with_samples(c, @far, samples, DateTime.add(@far, 180 * 60))
          c
        end)

      on_exit(fn ->
        unboxed.(fn ->
          for t <- ~w(hourly_stats viewer_flags viewer_samples streams),
              do: Repo.query!("DELETE FROM #{t} WHERE channel_id = $1", [c.id])

          Repo.query!("DELETE FROM channels WHERE id = $1", [c.id])
        end)
      end)

      %{c: c, unboxed: unboxed}
    end

    test "of overlapping hours both succeed, with the same result", %{c: c, unboxed: unboxed} do
      # Before, the second one's INSERT hit the rows the first had just
      # written: a duplicate key on hourly_stats.
      results =
        for {from, to} <- [{0, 3}, {1, 3}, {0, 2}, {0, 3}] do
          Task.async(fn ->
            unboxed.(fn ->
              Rollups.hourly(DateTime.add(@far, from * 3600), DateTime.add(@far, to * 3600))
            end)
          end)
        end
        |> Task.await_many(60_000)

      assert results == [:ok, :ok, :ok, :ok]

      hours =
        unboxed.(fn ->
          Repo.query!(
            "SELECT hour, samples, hours_watched FROM hourly_stats WHERE channel_id = $1 ORDER BY hour",
            [c.id]
          ).rows
        end)

      assert Enum.map(hours, &Enum.at(&1, 1)) == [59, 60, 60]
    end
  end
end
