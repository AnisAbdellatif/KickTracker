defmodule KickTracker.Metrics.AnomaliesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics.Anomalies

  @t0 ~U[2026-03-02 20:00:00Z]

  defp at(i), do: DateTime.add(@t0, i * 60)

  # An audience that builds over 15 minutes from the start, then wobbles
  # by a percent or two between readings, as real counts do.
  defp organic(n, level, opts \\ []) do
    ramp? = Keyword.get(opts, :ramp, true)

    for i <- 0..(n - 1) do
      share = if ramp?, do: min(1.0, 0.2 + i / 15 * 0.8), else: 1.0
      wobble = level * (0.015 * :math.sin(i * 1.3) + 0.01 * :math.cos(i * 0.7))
      round(level * share + wobble)
    end
  end

  # Chatters per minute: a share of the viewers.
  defp chat_of(viewers, share \\ 0.05), do: Enum.map(viewers, &round(&1 * share))

  defp input(viewers, chatters, opts \\ []) do
    n = length(viewers)

    %{
      started_at: DateTime.add(@t0, -30),
      ended_at: Keyword.get(opts, :ended_at, at(n)),
      viewers: viewers |> Enum.with_index() |> Enum.map(fn {v, i} -> {at(i), v} end),
      chat:
        chatters
        |> Enum.with_index()
        |> Map.new(fn {c, i} -> {DateTime.to_unix(at(i)), c} end),
      chat_gaps: Keyword.get(opts, :chat_gaps, []),
      hosts: Keyword.get(opts, :hosts, []),
      follows: Keyword.get(opts, :follows),
      hours_watched: Keyword.get(opts, :hours_watched),
      previous_ended_at: Keyword.get(opts, :previous_ended_at)
    }
  end

  defp kinds(findings), do: Enum.map(findings, & &1.kind)

  defp add_from(values, from, delta),
    do:
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> if i >= from, do: v + delta, else: v end)

  test "an organic stream has nothing to show" do
    viewers = organic(120, 1000)
    findings = Anomalies.findings(input(viewers, chat_of(viewers)), nil)
    assert findings == []
    assert Anomalies.level(findings) == :none
  end

  describe "jumps" do
    setup do
      base = organic(120, 1000)
      # 1 500 viewers arrive at minute 60 and stay; chat carries on as before.
      %{viewers: add_from(base, 60, 1500), chat: chat_of(base)}
    end

    test "viewers that arrive without chat are a finding", %{viewers: viewers, chat: chat} do
      assert [%{kind: :unexplained_jump, facts: f} = finding] =
               Anomalies.findings(input(viewers, chat), nil)

      assert f.viewers_before in 950..1050
      assert f.viewers_after in 2450..2550
      assert_in_delta f.chatters_after, f.chatters_before, 5
      assert DateTime.compare(finding.from, at(60)) == :lt
      assert DateTime.compare(finding.to, at(60)) == :gt
    end

    test "before and after on the same jump: chat that comes with the viewers explains it",
         %{viewers: viewers, chat: chat} do
      # Before: chat flat, a finding.
      assert kinds(Anomalies.findings(input(viewers, chat), nil)) == [:unexplained_jump]
      # After: chat grows with the viewers, as a real audience's would.
      assert Anomalies.findings(input(viewers, chat_of(viewers)), nil) == []
    end

    test "an incoming host near it explains it", %{viewers: viewers, chat: chat} do
      hosts = [{DateTime.add(at(60), 20), :hosted_by}]
      assert Anomalies.findings(input(viewers, chat, hosts: hosts), nil) == []

      # An outgoing one doesn't, nor an incoming one long before.
      for hosts <- [[{at(60), :hosting}], [{at(20), :hosted_by}]],
          do:
            assert(
              kinds(Anomalies.findings(input(viewers, chat, hosts: hosts), nil)) == [
                :unexplained_jump
              ]
            )
    end

    test "unknown chat around it is not judged", %{viewers: viewers, chat: chat} do
      gaps = [{at(57), at(63)}]
      assert Anomalies.findings(input(viewers, chat, chat_gaps: gaps), nil) == []
    end

    test "the start's own ramp is not a jump" do
      viewers = organic(60, 3000)
      assert Anomalies.findings(input(viewers, chat_of(viewers, 0.0)), nil) |> kinds() == []
    end
  end

  describe "drops" do
    setup do
      base = organic(120, 3000)
      %{base: base, viewers: add_from(base, 60, -2000)}
    end

    test "viewers that leave while chat carries on are a finding", %{base: base, viewers: viewers} do
      assert [%{kind: :unexplained_drop, facts: f}] =
               Anomalies.findings(input(viewers, chat_of(base)), nil)

      assert f.viewers_before > 2800 and f.viewers_after < 1200
    end

    test "chat leaving with them, an outgoing host, or the stream's end explain it",
         %{base: base, viewers: viewers} do
      assert Anomalies.findings(input(viewers, chat_of(viewers)), nil) == []

      assert Anomalies.findings(input(viewers, chat_of(base), hosts: [{at(61), :hosting}]), nil) ==
               []

      # The same drop 6 minutes before the stream ends.
      {viewers, base} = {Enum.take(viewers, 66), Enum.take(base, 66)}
      assert Anomalies.findings(input(viewers, chat_of(base)), nil) == []
    end
  end

  describe "flat plateaus" do
    # A normal start, then a count that barely moves for over an hour.
    defp flat(n) do
      for i <- 0..(n - 1),
          do: if(i < 15, do: round(2000 * (0.2 + i / 15 * 0.8)), else: 2000 + rem(i, 2))
    end

    test "a count that barely moves is a finding; a normal one isn't" do
      viewers = flat(90)

      assert [%{kind: :flat_plateau, facts: f} = finding] =
               Anomalies.findings(input(viewers, chat_of(viewers)), nil)

      assert_in_delta f.level, 2000, 1
      assert f.noise < 0.002
      assert DateTime.diff(finding.to, finding.from) >= 60 * 60

      organic = organic(90, 2000)
      assert Anomalies.findings(input(organic, chat_of(organic)), nil) == []
    end

    test "judged against the channel's usual variation, within limits" do
      viewers = flat(90)
      input = input(viewers, chat_of(viewers))
      usual = fn noise -> %{Anomalies.baseline([]) | noise: noise} end

      # A channel whose counts usually move 2%: flat is under 0.5%.
      assert kinds(Anomalies.findings(input, usual.(0.02))) == [:flat_plateau]
      # One that's always flat still gets the absolute floor.
      assert kinds(Anomalies.findings(input, usual.(0.0001))) == [:flat_plateau]
    end
  end

  describe "cold starts" do
    setup do
      viewers = organic(90, 2000, ramp: false)
      %{viewers: viewers, chat: chat_of(viewers)}
    end

    test "an audience already there at the first reading is a finding",
         %{viewers: viewers, chat: chat} do
      assert [%{kind: :cold_start, facts: f}] = Anomalies.findings(input(viewers, chat), nil)
      assert f.share > 0.9
    end

    test "not after a stream that just ended, nor with an incoming host, nor for a channel that always starts full",
         %{viewers: viewers, chat: chat} do
      previous = DateTime.add(@t0, -5 * 60)
      assert Anomalies.findings(input(viewers, chat, previous_ended_at: previous), nil) == []

      assert Anomalies.findings(input(viewers, chat, hosts: [{@t0, :hosted_by}]), nil) == []

      usual = %{Anomalies.baseline([]) | start_share: 0.9}
      assert Anomalies.findings(input(viewers, chat), usual) == []
    end
  end

  describe "against the channel's usual figures" do
    test "much less chat than usual is a finding, and nothing is said without a baseline" do
      viewers = organic(120, 1000)
      input = input(viewers, chat_of(viewers, 0.01))
      usual = Anomalies.profile(input(viewers, chat_of(viewers, 0.05)))

      assert Anomalies.findings(input, nil) == []
      # Four earlier streams aren't enough to say what's usual.
      assert Anomalies.findings(input, Anomalies.baseline(List.duplicate(usual, 4))) == []

      assert [%{kind: :low_engagement, facts: f}] =
               Anomalies.findings(input, Anomalies.baseline(List.duplicate(usual, 5)))

      assert_in_delta f.engagement, 0.01, 0.002
      assert_in_delta f.usual, 0.05, 0.002
      assert f.streams == 5
    end

    test "few follows for the hours watched, only when follows are known" do
      viewers = organic(120, 1000)
      chat = chat_of(viewers)
      usual = %{Anomalies.baseline([]) | follows_per_khw: 20.0}

      assert [%{kind: :low_follows, facts: %{rate: rate}}] =
               Anomalies.findings(input(viewers, chat, follows: 2, hours_watched: 1000.0), usual)

      assert_in_delta rate, 2.0, 0.001
      # Unknown follows (ingress coverage incomplete), or too few hours to say.
      assert Anomalies.findings(input(viewers, chat, follows: nil, hours_watched: 1000.0), usual) ==
               []

      assert Anomalies.findings(input(viewers, chat, follows: 0, hours_watched: 10.0), usual) ==
               []
    end
  end

  test "a stream with several kinds of findings" do
    base = organic(120, 1000)
    viewers = add_from(base, 60, 1500)
    usual = Anomalies.profile(input(base, chat_of(base, 0.2)))

    findings =
      Anomalies.findings(
        input(viewers, chat_of(base)),
        Anomalies.baseline(List.duplicate(usual, 5))
      )

    assert kinds(findings) |> Enum.sort() == [:low_engagement, :unexplained_jump]
    assert Anomalies.level(findings) == :several
  end

  property "the readings' order and repeats don't change the findings" do
    base = organic(120, 1000)
    viewers = add_from(base, 60, 1500)
    input = input(viewers, chat_of(base))
    expected = Anomalies.findings(input, nil)

    check all(seed <- integer(), dupes <- integer(0..20)) do
      :rand.seed(:exsss, {seed, 7, 11})
      readings = Enum.take_random(input.viewers, dupes) ++ input.viewers
      assert Anomalies.findings(%{input | viewers: Enum.shuffle(readings)}, nil) == expected
    end
  end

  property "without chat coverage, nothing is judged against chat" do
    check all(
            at_step <- integer(20..100),
            delta <- integer(-900..3000),
            share <- float(min: 0.0, max: 0.2)
          ) do
      viewers = add_from(organic(120, 1000), at_step, delta)
      input = input(viewers, chat_of(viewers, share), chat_gaps: [{at(-1), at(121)}])
      usual = %{Anomalies.baseline([]) | engagement: 1.0}

      judged_on_chat = [:unexplained_jump, :unexplained_drop, :low_engagement]
      assert Enum.all?(Anomalies.findings(input, usual), &(&1.kind not in judged_on_chat))
      assert Anomalies.profile(input).engagement == nil
    end
  end
end
