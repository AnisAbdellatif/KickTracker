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
end
