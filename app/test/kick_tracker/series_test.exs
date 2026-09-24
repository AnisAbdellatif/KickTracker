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
    %{chatters: counts} = Series.active_chatters(stream, 5)
    # Minute m counts (m - 5, m]: user 1 at minutes 1-2, user 2 at minute 3.
    assert Enum.slice(counts, 0, 9) == [0, 1, 1, 2, 2, 2, 2, 1, 0]
  end
end
