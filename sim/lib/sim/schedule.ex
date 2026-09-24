defmodule Sim.Schedule do
  @moduledoc """
  When a simulated channel is live. Pure, and a function of time alone: the
  same question at the same moment always gives the same answer, so the
  simulator can be restarted, queried about the past, or run fast without
  keeping any history.

  `:always` means a stream that restarts at midnight UTC each day, which is
  how a 24/7 rerun channel behaves and keeps `started_at` meaningful.
  """

  alias Sim.Scenario.Channel

  @type window :: %{started_at: DateTime.t(), ends_at: DateTime.t(), duration_s: pos_integer()}

  @always %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 0, start_minute: 0, duration_min: 1440}

  @doc """
  The stream running at `at`, or nil when the channel is offline.

  Manual overrides (from the control API) come first: a stream started by
  hand wins over the schedule, and a scheduled stream ended early by hand
  is over from that moment.
  """
  @spec stream_at(Channel.t(), DateTime.t()) :: window() | nil
  def stream_at(%Channel{} = channel, at) do
    Enum.find(channel.overrides.manual, &contains?(&1, at)) ||
      channel |> scheduled(at_dates(channel, at)) |> Enum.find(&contains?(&1, at))
  end

  @doc "Whether the channel is live at `at`."
  @spec live?(Channel.t(), DateTime.t()) :: boolean()
  def live?(channel, at), do: stream_at(channel, at) != nil

  @doc """
  Every stream window that overlaps `from..to`, oldest first, overrides
  included. This is what makes months of history computable without
  simulating forward.
  """
  @spec windows_between(Channel.t(), DateTime.t(), DateTime.t()) :: [window()]
  def windows_between(%Channel{} = channel, from, to) do
    dates =
      case schedule(channel) do
        nil ->
          []

        schedule ->
          Date.range(
            from |> DateTime.to_date() |> Date.add(-days_back(schedule)),
            DateTime.to_date(to)
          )
      end

    (scheduled(channel, dates) ++ channel.overrides.manual)
    |> Enum.filter(&overlaps?(&1, from, to))
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  @doc "When the channel next goes live at or after `at`, or nil within the next week."
  @spec next_start(Channel.t(), DateTime.t()) :: DateTime.t() | nil
  def next_start(%Channel{} = channel, at) do
    date = DateTime.to_date(at)

    (scheduled(channel, Date.range(date, Date.add(date, 8))) ++ channel.overrides.manual)
    |> Enum.map(& &1.started_at)
    |> Enum.filter(&(DateTime.compare(&1, at) != :lt))
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  @doc """
  A window as it really ran: if it was ended early by hand, its end is
  when that happened. Streams keep their planned `duration_s`, so the
  viewer curve doesn't jump when a stream is cut short.
  """
  @spec effective(Channel.t(), window()) :: window()
  def effective(%Channel{} = channel, window) do
    case Enum.find(channel.overrides.cuts, &same_start?(&1, window)) do
      nil -> window
      cut -> %{window | ends_at: cut.ended_at}
    end
  end

  @doc """
  The up-to-date version of a window seen earlier: a manual stream's
  current end, or a scheduled one's after any cut. This is how the end
  event reports when a stream really ended, even if it was cut short after
  the window was first seen.
  """
  @spec current(Channel.t(), window()) :: window()
  def current(%Channel{} = channel, window) do
    Enum.find(channel.overrides.manual, &same_start?(&1, window)) || effective(channel, window)
  end

  defp schedule(%Channel{schedule: :never}), do: nil
  defp schedule(%Channel{schedule: :always}), do: @always
  defp schedule(%Channel{schedule: schedule}), do: schedule

  defp at_dates(channel, at) do
    case schedule(channel) do
      nil -> []
      schedule -> Enum.map(0..days_back(schedule), &Date.add(DateTime.to_date(at), -&1))
    end
  end

  # The scheduled windows starting on these dates, as they really ran: a
  # window cut before it began is dropped entirely.
  defp scheduled(channel, dates) do
    case schedule(channel) do
      nil ->
        []

      schedule ->
        dates
        |> Enum.flat_map(&List.wrap(window_starting_on(schedule, &1)))
        |> Enum.map(&effective(channel, &1))
        |> Enum.filter(&(DateTime.compare(&1.ends_at, &1.started_at) == :gt))
    end
  end

  defp same_start?(a, b), do: DateTime.compare(a.started_at, b.started_at) == :eq

  # A stream can start on an earlier day and still be running, so we look
  # back far enough to cover the longest possible one.
  defp days_back(%{duration_min: duration_min}), do: div(duration_min, 1440) + 1

  defp window_starting_on(schedule, date) do
    if Date.day_of_week(date) in schedule.days do
      started_at =
        date
        |> DateTime.new!(Time.new!(schedule.start_hour, schedule.start_minute, 0), "Etc/UTC")

      duration_s = schedule.duration_min * 60

      %{
        started_at: started_at,
        ends_at: DateTime.add(started_at, duration_s, :second),
        duration_s: duration_s
      }
    end
  end

  defp contains?(window, at) do
    DateTime.compare(at, window.started_at) != :lt and DateTime.compare(at, window.ends_at) == :lt
  end

  defp overlaps?(window, from, to) do
    DateTime.compare(window.started_at, to) != :gt and
      DateTime.compare(window.ends_at, from) == :gt
  end
end
