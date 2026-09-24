defmodule KickTracker.SeriesTest do
  @moduledoc "Chart series: gaps stay gaps, silence is zero only when we were listening."

  # Not async: writes hypertables.
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Rollups, Series}

  @t0 ~U[2026-03-02 20:00:00Z]
  defp at(min), do: DateTime.add(@t0, min * 60)

  setup do
    c = channel!(slug: "somestreamer")
    s = stream!(c, at(0), at(60))
    # Readings every minute, except a 10-minute hole from 20:20 to 20:30.
    samples = for m <- Enum.to_list(0..19) ++ Enum.to_list(30..59), do: {at(m), 100 + m}
    samples!(c, s, samples)
    covered!(c, "api", at(0), at(19))
    covered!(c, "api", at(30), at(59))
    %{c: c, s: s}
  end

  test "raw viewers break where readings are missing, and the hole is shaded", %{c: c} do
    v = Series.viewers(c, at(0), at(60), :raw)
    assert v.res == "raw"
    assert length(Enum.reject(v.avg, &is_nil/1)) == 50
    assert Enum.count(v.avg, &is_nil/1) == 1
    assert v.gaps == [[DateTime.to_unix(at(20)), DateTime.to_unix(at(30))]]
  end

  test "bucketed viewers are nil where empty, never 0, with avg and max", %{c: c} do
    v = Series.viewers(c, at(0), at(60), :m5)
    assert length(v.t) == 12
    assert Enum.slice(v.avg, 4, 2) == [nil, nil]
    assert Enum.at(v.max, 0) == 104 and Enum.at(v.avg, 0) == 102
    refute 0 in v.avg
  end

  test "hourly and daily viewers come from the rollup", %{c: c} do
    Rollups.hourly(at(0), at(60))
    h = Series.viewers(c, at(-60), at(120), :hour)
    assert Enum.reject(h.avg, &is_nil/1) != []
    assert Enum.count(h.avg, &is_nil/1) == 2
    d = Series.viewers(c, at(-600), at(600), :day)
    assert d.res == "1d" and Enum.reject(d.max, &is_nil/1) == [159]
  end

  test "chat counts are 0 when we were listening and nil when we weren't", %{c: c} do
    covered!(c, "chat", at(0), at(9))

    Repo.insert_all("chat_minutes", [%{channel_id: c.id, minute: at(2), messages: 7, chatters: 3}])

    chat = Series.chat(c, at(0), at(20), :raw)
    assert Enum.at(chat.messages, 2) == 7
    assert Enum.at(chat.messages, 5) == 0
    assert Enum.at(chat.messages, 15) == nil
    assert chat.gaps == [[DateTime.to_unix(at(10)), DateTime.to_unix(at(20))]]
  end

  test "coverage is the share of the period collected, from when tracking began", %{c: c} do
    c = %{c | tracked_since: at(0)}
    assert_in_delta Series.coverage(c, "api", at(-600), at(60)), 50 / 60, 0.001
  end

  test "active chatters count distinct people over the window", %{c: c, s: s} do
    covered!(c, "chat", at(0), at(59))

    Repo.insert_all("chat_minute_users", [
      %{channel_id: c.id, minute: at(1), user_id: 1, messages: 1},
      %{channel_id: c.id, minute: at(2), user_id: 1, messages: 2},
      %{channel_id: c.id, minute: at(3), user_id: 2, messages: 1}
    ])

    stream = KickTracker.Reports.stream(s)
    %{chatters: counts} = Series.active_chatters(stream, 5, now: at(120))
    # Minute m counts (m - 5, m]: user 1 at minutes 1-2, user 2 at minute 3.
    assert Enum.slice(counts, 0, 9) == [0, 1, 1, 2, 2, 2, 2, 1, 0]
  end

  test "active chatters are nil where the per-minute detail is no longer kept", %{c: c, s: s} do
    covered!(c, "chat", at(0), at(59))
    stream = KickTracker.Reports.stream(s)

    # Long past the 90 days: before, 0 everywhere, as if nobody chatted.
    old = Series.active_chatters(stream, 5, now: DateTime.add(at(60), 91, :day))
    assert Enum.all?(old.chatters, &is_nil/1)

    # A stream straddling the boundary: nil up to where every minute of
    # the window is still kept, counts after.
    edge = DateTime.add(at(30), 90, :day)
    %{t: t, chatters: counts} = Series.active_chatters(stream, 5, now: edge)
    kept_from = DateTime.to_unix(at(30))

    for {minute, n} <- Enum.zip(t, counts) do
      if minute - 4 * 60 >= kept_from, do: assert(n == 0), else: assert(is_nil(n))
    end
  end

  test "active chatters read only the stream's own range of per-minute rows", %{c: c, s: s} do
    covered!(c, "chat", at(0), at(59))

    # Plenty of chat long before the stream: it must neither count nor be read.
    Repo.insert_all(
      "chat_minute_users",
      for(
        m <- 1..300,
        u <- 1..3,
        do: %{channel_id: c.id, minute: at(-m * 60), user_id: u, messages: 1}
      )
    )

    Repo.insert_all("chat_minute_users", [
      %{channel_id: c.id, minute: at(1), user_id: 9, messages: 1}
    ])

    test_pid = self()
    handler = "active-chatters-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:kick_tracker, :repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ "chat_minute_users",
          do: send(test_pid, {:query, meta.query, meta.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{chatters: counts} =
      Series.active_chatters(KickTracker.Reports.stream(s), 5, now: at(120))

    assert Enum.slice(counts, 0, 7) == [0, 1, 1, 1, 1, 1, 0]
    assert_received {:query, sql, params}

    # Both ends of the stream bound the scan itself, so TimescaleDB skips
    # other chunks and the index range is the stream's. Before, the scan
    # was joined to every minute with no bound of its own: the channel's
    # whole history was read once per minute of the stream.
    plan = Repo.query!("EXPLAIN " <> sql, params).rows |> List.flatten()
    bounds = Enum.filter(plan, &(&1 =~ ~r/(Index Cond|Filter).*minute/))
    assert Enum.any?(bounds, &(&1 =~ "minute >" and &1 =~ "minute <")), Enum.join(plan, "\n")
  end

  describe "viewer peaks and exclusions" do
    setup %{c: c} do
      s = stream!(c, at(100), at(110))

      samples!(
        c,
        s,
        for({v, i} <- Enum.with_index([500, 510, 9000, 505, 498]), do: {at(101 + i), v})
      )

      Rollups.hourly(at(100), at(110))
      %{glitch: s}
    end

    test "a flagged reading is in no bucket's max, as in the hourly rollup", %{c: c} do
      # Before, the 5-minute max was the glitch, 9000, and the hourly one 510.
      for res <- [:m5, :m15] do
        v = Series.viewers(c, at(100), at(110), res)
        assert v.max |> Enum.reject(&is_nil/1) |> Enum.max() == 510
        # The reading still counts in the average, like hourly_stats'.
        assert Enum.any?(v.avg, &(&1 && &1 > 510))
      end

      h = Series.viewers(c, at(60), at(180), :hour)
      assert h.max |> Enum.reject(&is_nil/1) |> Enum.max() == 510

      raw = Series.viewers(c, at(100), at(110), :raw)
      assert 9000 in raw.avg and 9000 not in raw.max
    end

    test "an excluded stream's readings are left out, except on its own page", %{
      c: c,
      glitch: s
    } do
      Repo.query!(
        "INSERT INTO stream_overrides (kind, stream_id, inserted_at) VALUES ('exclude', $1, now())",
        [s]
      )

      assert Series.viewers(c, at(100), at(110), :m5).avg |> Enum.all?(&is_nil/1)
      assert Series.viewers(c, at(100), at(110), :raw).avg == []
      assert length(Series.viewers(c, at(100), at(110), :raw, stream_ids: [s]).avg) == 5
    end
  end

  test "support is nil and shaded where the ingress wasn't covered, 0 where it was", %{c: c} do
    covered!(c, "ingress", at(0), at(10))

    Repo.insert_all("support_events", [
      %{
        message_id: "k",
        channel_id: c.id,
        occurred_at: at(2),
        kind: "kicks",
        quantity: 50,
        payload: %{}
      }
    ])

    sup = Series.support(c, at(0), at(60), :raw)
    assert Enum.at(sup.kicks, 2) == 50
    assert Enum.at(sup.subs, 5) == 0
    # Before, 0 here too, and no gaps at all.
    assert Enum.at(sup.subs, 40) == nil
    assert [[from, _to]] = sup.gaps
    assert from > DateTime.to_unix(at(10))
  end

  test "followers are bucketed beyond 12 hours: last, min and max per bucket", %{c: c} do
    Repo.insert_all(
      "follower_samples",
      for(
        i <- 0..(30 * 96),
        do: %{channel_id: c.id, observed_at: at(i * 15), followers: 1000 + i}
      )
    )

    f = Series.followers(c, at(0), DateTime.add(at(0), 30, :day))
    assert f.res == "1h" and length(f.t) == 30 * 24
    assert [1003 | _] = f.v
    assert [1000 | _] = f.min
    assert [1003 | _] = f.max

    raw = Series.followers(c, at(0), at(600))
    assert raw.res == "raw" and length(raw.t) == 40
  end

  test "whether a timezone is whole hours from UTC" do
    assert Series.whole_hour_offsets?("Europe/Berlin", at(0), at(60))
    refute Series.whole_hour_offsets?("Asia/Kolkata", at(0), at(60))
    refute Series.whole_hour_offsets?("Asia/Kathmandu", at(0), at(60))
  end
end
