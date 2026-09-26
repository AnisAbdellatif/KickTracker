defmodule KickTracker.Metrics.Anomalies do
  @moduledoc """
  Signs that a stream's audience may not be what its viewer count says
  (project.md §19.4): viewers that jump or drop while chat doesn't move,
  a count that stays unnaturally flat, an audience already there at the
  first reading, and far less chat or far fewer follows than the
  channel's own streams usually have. Pure.

  Each finding says what was seen, when, and the figures it rests on, for
  an admin to review. None is proof: a front-page placement, a
  followers-only chat or a watch party can look the same. Nothing here is
  shown publicly.

  Only what we observed is judged (AGENTS.md §7): a reading is compared
  with chat only in minutes chat coverage says we were listening, windows
  never reach across a gap in the readings, and a comparison with the
  channel's usual figures needs `@min_baseline` earlier streams that have
  that figure. A host (Kick's raid) arriving explains a jump, and one
  leaving explains a drop.

  Engagement is chatters per viewer: the per-minute distinct chatters
  (`chat_minutes`, kept forever) summed over the stream's readings,
  divided by the viewers summed over the same readings. Everything here
  reads tables that are kept forever, so any result can be computed again.
  """

  # Readings further apart than this don't share a window.
  @max_gap_s 150

  # A step: the median of the 5 readings after a point against the 5
  # before, by at least `@step_abs` viewers and `@step_rel` of the level.
  @side 5
  @step_abs 100
  @step_rel 0.3
  # Chat should move at least this share as much as viewers do.
  @chat_follow 0.25
  # A start ramps up for a while; its rise isn't a jump. The end winds
  # down; its fall isn't a drop.
  @ramp_s 15 * 60
  @wind_down_s 10 * 60
  # How close to a step a host counts as its cause (its time is when we
  # received it).
  @host_window_s 5 * 60

  # Flatness: the median absolute change between readings over a window
  # of `@flat_window` readings, relative to the window's median level.
  @flat_window 20
  @flat_min_level 100
  # Flat is below this share of the channel's usual variation, but never
  # above `@flat_max`, and always when below `@flat_floor`.
  @flat_share 0.25
  @flat_floor 0.002
  @flat_max 0.01
  @flat_min_s 20 * 60

  # A start: the first readings against the level the stream settles at
  # once its ramp is over (the median of its readings from 15 minutes to
  # an hour in, when there are at least `@settled_min` of them). Not the
  # whole stream's median: a stream that later loses most of its audience
  # would make an ordinary start look full.
  @cold_first 3
  @settled_until_s 60 * 60
  @settled_min 10
  @cold_within_s 5 * 60
  @cold_share 0.6
  @cold_min_level 100
  # An audience still there from a stream that just ended isn't a cold start.
  @cold_after_previous_s 30 * 60
  # With a baseline, only a start well above the channel's usual one.
  @cold_over_usual 1.5

  @min_judged 30
  @min_baseline 5
  @low_engagement_share 0.5
  @low_follows_share 0.33
  @min_hours_watched 50

  @baseline_keys [:engagement, :noise, :follows_per_khw, :start_share]

  @type host :: {DateTime.t(), :hosted_by | :hosting}

  @type input :: %{
          required(:started_at) => DateTime.t(),
          required(:ended_at) => DateTime.t() | nil,
          required(:viewers) => [{DateTime.t(), non_neg_integer()}],
          # Distinct chatters per minute, by the minute's unix time.
          required(:chat) => %{integer() => non_neg_integer()},
          # Stretches chat coverage doesn't cover.
          required(:chat_gaps) => [{DateTime.t(), DateTime.t()}],
          required(:hosts) => [host()],
          # Nil when not known (ingress coverage incomplete).
          required(:follows) => non_neg_integer() | nil,
          required(:hours_watched) => float() | nil,
          required(:previous_ended_at) => DateTime.t() | nil
        }

  @type profile :: %{
          readings: non_neg_integer(),
          judged: non_neg_integer(),
          settled_viewers: number() | nil,
          engagement: float() | nil,
          noise: float() | nil,
          follows_per_khw: float() | nil,
          start_share: float() | nil
        }

  @type baseline :: %{
          streams: non_neg_integer(),
          engagement: float() | nil,
          noise: float() | nil,
          follows_per_khw: float() | nil,
          start_share: float() | nil
        }

  @type kind ::
          :unexplained_jump
          | :unexplained_drop
          | :flat_plateau
          | :cold_start
          | :low_engagement
          | :low_follows

  @type finding :: %{kind: kind(), from: DateTime.t(), to: DateTime.t(), facts: map()}

  @doc "The finding kinds, in the order they're listed."
  def kinds,
    do: [
      :unexplained_jump,
      :unexplained_drop,
      :flat_plateau,
      :cold_start,
      :low_engagement,
      :low_follows
    ]

  @doc """
  One stream's figures, compared later with the channel's usual ones.
  Any figure is nil when there isn't enough to say.
  """
  @spec profile(input()) :: profile()
  def profile(input) do
    readings = readings(input)
    judged = Enum.filter(readings, & &1.c)
    settled = settled(readings, input)

    %{
      readings: length(readings),
      judged: length(judged),
      settled_viewers: settled,
      engagement: engagement(judged),
      noise: readings |> runs() |> flat_windows() |> Enum.map(& &1.noise) |> median(),
      follows_per_khw: follows_per_khw(input),
      start_share: start_share(readings, input, settled)
    }
  end

  @doc """
  The channel's usual figures, from earlier streams' profiles: the median
  of each figure, or nil when fewer than #{@min_baseline} streams have it.
  """
  @spec baseline([profile()]) :: baseline()
  def baseline(profiles) do
    Map.new(@baseline_keys, fn key ->
      values = for p <- profiles, v = p[key], not is_nil(v), do: v
      {key, if(length(values) >= @min_baseline, do: median(values))}
    end)
    |> Map.put(:streams, length(profiles))
  end

  @doc "The stream's findings, oldest first. `baseline` may be nil."
  @spec findings(input(), baseline() | nil) :: [finding()]
  def findings(input, baseline) do
    baseline = baseline || baseline([])
    readings = readings(input)
    runs = runs(readings)
    profile = profile(input)

    (steps(runs, input) ++
       plateaus(runs, baseline) ++
       cold_start(readings, input, profile, baseline) ++
       low_engagement(readings, profile, baseline) ++
       low_follows(input, profile, baseline))
    |> Enum.sort_by(& &1.from, DateTime)
  end

  @doc """
  How much there is to look at: `:none`, `:some` (one kind of finding) or
  `:several` (more than one kind).
  """
  @spec level([finding()]) :: :none | :some | :several
  def level(findings) do
    case findings |> Enum.map(& &1.kind) |> Enum.uniq() |> length() do
      0 -> :none
      1 -> :some
      _ -> :several
    end
  end

  ## Readings

  # The stream's readings, oldest first, each with the chatters of its
  # minute, or nil where chat wasn't covered.
  defp readings(input) do
    input.viewers
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.map(fn {at, v} ->
      minute = div(DateTime.to_unix(at), 60) * 60
      c = if covered?(minute, input.chat_gaps), do: Map.get(input.chat, minute, 0)
      %{at: at, v: v, c: c}
    end)
  end

  # A minute counts as covered when its middle isn't in a gap.
  defp covered?(minute, gaps) do
    middle = DateTime.from_unix!(minute + 30)

    not Enum.any?(gaps, fn {from, to} ->
      DateTime.compare(middle, from) != :lt and DateTime.compare(middle, to) == :lt
    end)
  end

  # Stretches of readings with no gap longer than `@max_gap_s`.
  defp runs([]), do: []

  defp runs(readings) do
    readings
    |> Enum.chunk_while(
      [],
      fn r, acc ->
        case acc do
          [prev | _] ->
            if DateTime.diff(r.at, prev.at) > @max_gap_s,
              do: {:cont, Enum.reverse(acc), [r]},
              else: {:cont, [r | acc]}

          [] ->
            {:cont, [r]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp engagement(judged) when length(judged) < @min_judged, do: nil

  defp engagement(judged) do
    viewers = judged |> Enum.map(& &1.v) |> Enum.sum()
    if viewers > 0, do: (judged |> Enum.map(& &1.c) |> Enum.sum()) / viewers
  end

  defp follows_per_khw(%{follows: f, hours_watched: hw})
       when is_integer(f) and is_number(hw) and hw >= @min_hours_watched,
       do: f / hw * 1000

  defp follows_per_khw(_input), do: nil

  # The level after the start's ramp; nil for a stream too short to say.
  defp settled(readings, input) do
    values =
      for r <- readings,
          offset = DateTime.diff(r.at, input.started_at),
          offset >= @ramp_s and offset < @settled_until_s,
          do: r.v

    if length(values) >= @settled_min, do: median(values)
  end

  # The first readings' level against the settled one, when the first
  # reading is close enough to the start to show it.
  defp start_share(readings, input, settled) do
    with [first | _] <- readings,
         true <- DateTime.diff(first.at, input.started_at) <= @cold_within_s,
         true <- is_number(settled) and settled > 0 do
      median(readings |> Enum.take(@cold_first) |> Enum.map(& &1.v)) / settled
    else
      _ -> nil
    end
  end

  ## Steps: jumps and drops chat doesn't follow

  defp steps(runs, input) do
    runs
    |> Enum.flat_map(&step_candidates/1)
    |> Enum.chunk_while(
      [],
      fn cand, acc ->
        case acc do
          [prev | _]
          when prev.run == cand.run and prev.i + 1 == cand.i and prev.up? == cand.up? ->
            {:cont, [cand | acc]}

          [] ->
            {:cont, [cand]}

          _ ->
            {:cont, acc, [cand]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, acc, []}
      end
    )
    |> Enum.map(fn cluster -> Enum.max_by(cluster, &abs(&1.after_v - &1.before_v)) end)
    |> Enum.flat_map(&judge_step(&1, input))
  end

  defp step_candidates(run) do
    tuple = List.to_tuple(run)
    n = tuple_size(tuple)

    if n < 2 * @side do
      []
    else
      for i <- @side..(n - @side) do
        before = for j <- (i - @side)..(i - 1), do: elem(tuple, j)
        after_ = for j <- i..(i + @side - 1), do: elem(tuple, j)
        before_v = median(Enum.map(before, & &1.v))
        after_v = median(Enum.map(after_, & &1.v))

        %{
          run: hd(run).at,
          i: i,
          at: elem(tuple, i).at,
          before: before,
          after: after_,
          before_v: before_v,
          after_v: after_v,
          up?: after_v > before_v
        }
      end
      |> Enum.filter(&(abs(&1.after_v - &1.before_v) >= max(@step_abs, @step_rel * &1.before_v)))
    end
  end

  defp judge_step(step, input) do
    kind = if step.up?, do: :unexplained_jump, else: :unexplained_drop
    chat = Enum.map(step.before ++ step.after, & &1.c)

    cond do
      # Unknown chat on either side: nothing to judge.
      Enum.any?(chat, &is_nil/1) -> []
      step.up? and DateTime.diff(step.at, input.started_at) < @ramp_s -> []
      not step.up? and winding_down?(step.at, input.ended_at) -> []
      host_near?(input.hosts, step.at, if(step.up?, do: :hosted_by, else: :hosting)) -> []
      true -> chat_judgement(step, kind)
    end
  end

  defp winding_down?(_at, nil), do: false
  defp winding_down?(at, ended_at), do: DateTime.diff(ended_at, at) < @wind_down_s

  defp host_near?(hosts, at, kind) do
    Enum.any?(hosts, fn {h_at, h_kind} ->
      h_kind == kind and abs(DateTime.diff(h_at, at)) <= @host_window_s
    end)
  end

  defp chat_judgement(step, kind) do
    before_c = mean(Enum.map(step.before, & &1.c))
    after_c = mean(Enum.map(step.after, & &1.c))
    fv = step.after_v / max(step.before_v, 1)
    # +1 keeps a channel with almost no chat from swinging on one person.
    fc = (after_c + 1) / (before_c + 1)

    unexplained? =
      if step.up?,
        do: fc < 1 + @chat_follow * (fv - 1),
        else: fc > 1 - @chat_follow * (1 - fv)

    if unexplained? do
      [
        %{
          kind: kind,
          from: hd(step.before).at,
          to: List.last(step.after).at,
          facts: %{
            at: step.at,
            viewers_before: step.before_v,
            viewers_after: step.after_v,
            chatters_before: before_c,
            chatters_after: after_c
          }
        }
      ]
    else
      []
    end
  end

  ## Flat plateaus

  # Every window of `@flat_window` readings in a run with an audience:
  # its first and last index, level and noise.
  defp flat_windows(runs) do
    runs
    |> Enum.flat_map(&Enum.chunk_every(&1, @flat_window, 1, :discard))
    |> Enum.map(&flat_window/1)
    |> Enum.filter(&(&1.level >= @flat_min_level))
  end

  defp flat_window(window) do
    level = median(Enum.map(window, & &1.v))

    changes =
      window
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> abs(b.v - a.v) end)

    %{
      window: window,
      level: level,
      noise: if(level > 0, do: median(changes) / level),
      unchanged: Enum.count(changes, &(&1 == 0)) / length(changes)
    }
  end

  defp plateaus(runs, baseline) do
    threshold =
      case baseline.noise do
        nil -> @flat_floor
        usual -> usual |> Kernel.*(@flat_share) |> min(@flat_max) |> max(@flat_floor)
      end

    flat = runs |> flat_windows() |> Enum.filter(&(&1.noise <= threshold))

    # Overlapping flat windows (they come in order) make one stretch.
    flat
    |> Enum.reduce([], fn w, acc ->
      first = hd(w.window).at
      last = List.last(w.window).at

      case acc do
        [cur | rest] ->
          if DateTime.compare(first, cur.to) != :gt,
            do: [
              %{cur | to: Enum.max([cur.to, last], DateTime), windows: [w | cur.windows]} | rest
            ],
            else: [%{from: first, to: last, windows: [w]} | acc]

        [] ->
          [%{from: first, to: last, windows: [w]}]
      end
    end)
    |> Enum.reverse()
    |> Enum.filter(&(DateTime.diff(&1.to, &1.from) >= @flat_min_s))
    |> Enum.map(fn stretch ->
      %{
        kind: :flat_plateau,
        from: stretch.from,
        to: stretch.to,
        facts: %{
          level: median(Enum.map(stretch.windows, & &1.level)),
          noise: median(Enum.map(stretch.windows, & &1.noise)),
          usual_noise: baseline.noise,
          unchanged: mean(Enum.map(stretch.windows, & &1.unchanged))
        }
      }
    end)
  end

  ## A full audience at the first reading

  defp cold_start(readings, input, profile, baseline) do
    share = profile.start_share
    usual = baseline.start_share

    cond do
      is_nil(share) or share < @cold_share -> []
      profile.settled_viewers < @cold_min_level -> []
      usual && share < usual * @cold_over_usual -> []
      just_after_previous?(input) -> []
      host_near?(input.hosts, input.started_at, :hosted_by) -> []
      true -> [cold_finding(readings, input, profile, usual)]
    end
  end

  defp just_after_previous?(%{previous_ended_at: nil}), do: false

  defp just_after_previous?(%{previous_ended_at: prev, started_at: started}),
    do: DateTime.diff(started, prev) < @cold_after_previous_s

  defp cold_finding(readings, input, profile, usual) do
    first = Enum.take(readings, @cold_first)

    %{
      kind: :cold_start,
      from: input.started_at,
      to: List.last(first).at,
      facts: %{
        first_viewers: median(Enum.map(first, & &1.v)),
        settled_viewers: profile.settled_viewers,
        share: profile.start_share,
        usual_share: usual
      }
    }
  end

  ## Compared with the channel's usual figures

  defp low_engagement(readings, profile, baseline) do
    with e when is_number(e) <- profile.engagement,
         usual when is_number(usual) <- baseline.engagement,
         true <- e < usual * @low_engagement_share do
      [
        %{
          kind: :low_engagement,
          from: hd(readings).at,
          to: List.last(readings).at,
          facts: %{engagement: e, usual: usual, streams: baseline.streams}
        }
      ]
    else
      _ -> []
    end
  end

  defp low_follows(input, profile, baseline) do
    with rate when is_number(rate) <- profile.follows_per_khw,
         usual when is_number(usual) <- baseline.follows_per_khw,
         true <- rate < usual * @low_follows_share do
      [
        %{
          kind: :low_follows,
          from: input.started_at,
          to: input.ended_at || input.started_at,
          facts: %{
            follows: input.follows,
            hours_watched: input.hours_watched,
            rate: rate,
            usual: usual,
            streams: baseline.streams
          }
        }
      ]
    else
      _ -> []
    end
  end

  ## Helpers

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
