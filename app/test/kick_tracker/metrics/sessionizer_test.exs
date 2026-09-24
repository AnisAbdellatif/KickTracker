defmodule KickTracker.Metrics.SessionizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics.Sessionizer, as: S

  @s ~U[2026-01-05 20:00:00Z]
  @s2 ~U[2026-01-06 20:00:00Z]

  defp at(base, seconds), do: DateTime.add(base, seconds) |> S.norm()
  defp run(observations, state \\ S.new()), do: S.apply_all(state, observations)
  defp u(t), do: S.norm(t)

  describe "one stream" do
    test "a start event opens it, the end event closes it at Kick's end" do
      {state, actions} = run([{:live, @s, at(@s, 2)}, {:ended, @s, at(@s, 3600)}])
      assert actions == [{:open, u(@s)}, {:close, u(@s), at(@s, 3600), :event}]
      assert S.streams(state) == [{u(@s), at(@s, 3600), :event}]
      assert S.open_stream(state) == nil
    end

    test "the end event arriving first still gives the same stream" do
      {state, _} = run([{:ended, @s, at(@s, 3600)}, {:live, @s, at(@s, 2)}])
      assert S.streams(state) == [{u(@s), at(@s, 3600), :event}]
    end

    test "repeats change nothing" do
      {state, _} = run([{:live, @s, at(@s, 2)}, {:ended, @s, at(@s, 3600)}])
      assert {^state, []} = run([{:live, @s, at(@s, 2)}, {:ended, @s, at(@s, 3600)}], state)
    end

    test "the API lags the start: a poll missing it 30s in closes nothing" do
      {state, actions} = run([{:live, @s, at(@s, 1)}, {:offline, at(@s, 30)}])
      assert actions == [{:open, u(@s)}]
      assert S.open_stream(state) == u(@s)
    end

    test "without the end event, it ends at the last reading, once polls miss it for 90s" do
      readings = for m <- 0..10, do: {:live, @s, at(@s, 30 + m * 60)}
      last = at(@s, 30 + 600)

      {state, _} = run(readings ++ [{:offline, at(last, 60)}])
      assert S.open_stream(state) == u(@s)

      {state, actions} = run([{:offline, at(last, 120)}], state)
      assert actions == [{:close, u(@s), last, :poll}]
      assert S.streams(state) == [{u(@s), last, :poll}]
    end

    test "the end event corrects an end inferred from polling" do
      {state, _} = run([{:live, @s, at(@s, 30)}, {:offline, at(@s, 200)}])
      assert [{_, _, :poll}] = S.streams(state)

      {state, actions} = run([{:ended, @s, at(@s, 60)}], state)
      assert actions == [{:close, u(@s), at(@s, 60), :event}]
      assert S.streams(state) == [{u(@s), at(@s, 60), :event}]
    end

    test "the API still listing a stream after its end event neither reopens it nor adds samples" do
      {state, _} = run([{:live, @s, at(@s, 1)}, {:ended, @s, at(@s, 3600)}])
      assert {^state, []} = run([{:live, @s, at(@s, 3610)}], state)

      refute S.sample?(state, @s, at(@s, 3610))
      assert S.sample?(state, @s, at(@s, 3590))
    end

    test "a short disconnect Kick treats as the same stream reopens it" do
      {state, _} = run([{:live, @s, at(@s, 30)}, {:offline, at(@s, 150)}])
      assert S.open_stream(state) == nil

      {state, actions} = run([{:live, @s, at(@s, 210)}], state)
      assert actions == [{:reopen, u(@s)}]
      assert S.open_stream(state) == u(@s)
    end
  end

  test "an offline poll that arrived before the stream's evidence still ends it" do
    # Polls reach the process in order in practice; the rule holds anyway.
    {state, _} = run([{:offline, at(@s, 600)}, {:live, @s, at(@s, 30)}])
    assert S.streams(state) == [{u(@s), at(@s, 30), :poll}]
  end

  describe "several streams" do
    test "a newer start closes the open stream at its last evidence" do
      {state, actions} =
        run([{:live, @s, at(@s, 30)}, {:live, @s, at(@s, 90)}, {:live, @s2, at(@s2, 5)}])

      assert actions == [
               {:open, u(@s)},
               {:close, u(@s), at(@s, 90), :poll},
               {:open, u(@s2)}
             ]

      assert S.open_stream(state) == u(@s2)
    end

    test "late evidence about an older stream is recorded, not dropped, and moves its end later" do
      {state, actions} = run([{:live, @s2, at(@s2, 5)}, {:live, @s, at(@s, 60)}])
      assert actions == [{:open, u(@s2)}, {:close, u(@s), at(@s, 60), :poll}]

      {state, actions} = run([{:live, @s, at(@s, 120)}, {:live, @s, at(@s, 30)}], state)
      assert actions == [{:close, u(@s), at(@s, 120), :poll}]
      assert S.open_stream(state) == u(@s2)
    end

    test "an old offline poll doesn't touch a newer stream" do
      {state, _} = run([{:live, @s2, at(@s2, 5)}])
      assert {state, []} = run([{:offline, at(@s, 7200)}], state)
      assert S.open_stream(state) == u(@s2)
    end
  end

  test "starting from the database: an open stream continues, a poll-closed one can reopen" do
    state =
      S.new([
        %{started_at: @s, ended_at: at(@s, 600), end_source: "poll", last_live_at: at(@s, 600)},
        %{started_at: @s2, ended_at: nil, end_source: nil, last_live_at: at(@s2, 300)}
      ])

    assert S.open_stream(state) == u(@s2)
    assert {_, []} = run([{:live, @s2, at(@s2, 360)}], state)
    assert {_, [{:close, _, closed_at, :poll}]} = run([{:offline, at(@s2, 400)}], state)
    assert closed_at == at(@s2, 300)
  end

  # --- order independence -------------------------------------------------

  # A true history of streams, and every observation it would produce: a
  # start event, a reading every minute, an end event, and a few offline
  # polls after each end.
  defp history do
    gen all(
          streams <- list_of({integer(3..600), integer(2..300)}, min_length: 1, max_length: 4),
          reading_offset <- integer(1..59),
          # The API keeps listing a stream for up to ~20s after it ends.
          lag <- one_of([constant(nil), integer(1..19)])
        ) do
      {truth, _} =
        Enum.map_reduce(streams, ~U[2026-01-01 00:00:00Z], fn {gap_min, dur_min}, t ->
          s = DateTime.add(t, gap_min * 60)
          e = DateTime.add(s, dur_min * 60)
          {{u(s), u(e)}, e}
        end)

      observations =
        truth
        |> Enum.with_index()
        |> Enum.map(fn {{s, e}, i} ->
          next = Enum.at(truth, i + 1)

          readings =
            for(
              t <- 0..div(DateTime.diff(e, s) - reading_offset, 60),
              do: at(s, reading_offset + t * 60)
            ) ++
              if(lag, do: [at(e, lag)], else: [])

          offline =
            for k <- 0..3,
                o = at(e, 30 + k * 60),
                next == nil or DateTime.before?(o, elem(next, 0)),
                do: {:offline, o}

          %{
            start: {:live, s, at(s, 1)},
            readings: Enum.map(readings, &{:live, s, &1}),
            ended: {:ended, s, e},
            offline: offline
          }
        end)

      {truth, observations}
    end
  end

  defp shuffled_with_repeats(list) do
    gen all(
          order <- constant(list) |> map(&Enum.shuffle/1),
          repeats <- list_of(member_of(list), max_length: 5)
        ) do
      Enum.shuffle(order ++ repeats)
    end
  end

  property "with every end event, any order and any repeats give exactly the true streams" do
    check all(
            {truth, per_stream} <- history(),
            all = Enum.flat_map(per_stream, &([&1.start, &1.ended] ++ &1.readings ++ &1.offline)),
            observations <- shuffled_with_repeats(all),
            max_runs: 200
          ) do
      {state, _} = run(observations)
      assert S.streams(state) == Enum.map(truth, fn {s, e} -> {s, e, :event} end)
    end
  end

  property "with events lost, every stream still appears and ends at its last live evidence" do
    check all(
            {truth, per_stream} <- history(),
            keep <- list_of({boolean(), boolean(), boolean()}, length: length(truth)),
            kept = Enum.zip(per_stream, keep),
            all =
              Enum.flat_map(kept, fn {o, {start?, end?, _}} ->
                if(start?, do: [o.start], else: []) ++
                  if(end?, do: [o.ended], else: []) ++ o.readings ++ o.offline
              end),
            observations <- shuffled_with_repeats(all),
            max_runs: 200
          ) do
      {state, _} = run(observations)
      found = S.streams(state)
      assert Enum.map(found, &elem(&1, 0)) == Enum.map(truth, &elem(&1, 0))

      last = length(truth) - 1

      for {{{s, e}, {o, {start?, end?, _}}}, i} <- Enum.with_index(Enum.zip(truth, kept)) do
        {^s, ended_at, source} = Enum.at(found, i)
        evidence = Enum.map(o.readings, &elem(&1, 2)) ++ if(start?, do: [at(s, 1)], else: [])
        last_seen = Enum.max(evidence, DateTime)

        cond do
          end? ->
            assert {ended_at, source} == {e, :event}

          i < last ->
            assert {ended_at, source} == {last_seen, :poll}

          Enum.any?(o.offline, fn {:offline, t} -> DateTime.diff(t, last_seen) >= 90 end) ->
            assert {ended_at, source} == {last_seen, :poll}

          true ->
            # No poll missed it for long enough: still open, or closed at
            # the same last evidence, depending on arrival order.
            assert {ended_at, source} in [{nil, nil}, {last_seen, :poll}]
        end
      end
    end
  end
end
