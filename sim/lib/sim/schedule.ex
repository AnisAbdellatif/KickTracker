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

  @doc "The stream running at `at`, or nil when the channel is offline."
  @spec stream_at(Channel.t(), DateTime.t()) :: window() | nil
  def stream_at(%Channel{schedule: :never}, _at), do: nil

  def stream_at(%Channel{schedule: :always} = channel, at),
    do: find(%{channel | schedule: @always}, at)

  def stream_at(%Channel{} = channel, at), do: find(channel, at)

  @doc "Whether the channel is live at `at`."
  @spec live?(Channel.t(), DateTime.t()) :: boolean()
  def live?(channel, at), do: stream_at(channel, at) != nil

  @doc """
  Every stream window that overlaps `from..to`, oldest first. This is what
  makes months of history computable without simulating forward.
  """
  @spec windows_between(Channel.t(), DateTime.t(), DateTime.t()) :: [window()]
  def windows_between(%Channel{schedule: :never}, _from, _to), do: []

  def windows_between(%Channel{} = channel, from, to) do
    schedule = schedule(channel)
    first = from |> DateTime.to_date() |> Date.add(-days_back(schedule))
    last = DateTime.to_date(to)

    Date.range(first, last)
    |> Enum.flat_map(&List.wrap(window_starting_on(schedule, &1)))
    |> Enum.filter(&overlaps?(&1, from, to))
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  @doc "When the channel next goes live at or after `at`, or nil within the next week."
  @spec next_start(Channel.t(), DateTime.t()) :: DateTime.t() | nil
  def next_start(%Channel{schedule: :never}, _at), do: nil

  def next_start(%Channel{} = channel, at) do
    schedule = schedule(channel)
    date = DateTime.to_date(at)

    Date.range(date, Date.add(date, 8))
    |> Enum.flat_map(&List.wrap(window_starting_on(schedule, &1)))
    |> Enum.map(& &1.started_at)
    |> Enum.filter(&(DateTime.compare(&1, at) != :lt))
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp schedule(%Channel{schedule: :always}), do: @always
  defp schedule(%Channel{schedule: schedule}), do: schedule

  defp find(channel, at) do
    schedule = schedule(channel)

    0..days_back(schedule)
    |> Enum.map(&Date.add(DateTime.to_date(at), -&1))
    |> Enum.flat_map(&List.wrap(window_starting_on(schedule, &1)))
    |> Enum.find(&contains?(&1, at))
  end

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
