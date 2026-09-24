defmodule Sim.Scenarios do
  @moduledoc """
  Ready-made scenarios, and loading one from a file.

  A scenario file is an `.exs` script whose last expression is the keyword
  list `Sim.Scenario.new/1` takes, so a scenario is data, not code that has
  to be maintained:

      [
        seed: 7,
        channels: [
          [slug: "bigstreamer", peak_viewers: 20_000, schedule: %{days: [1, 2, 3, 4, 5], start_hour: 19, duration_min: 300}],
          [slug: "smallstreamer", peak_viewers: 40]
        ],
        faults: [drop_webhooks: 0.05]
      ]
  """

  alias Sim.Scenario

  @doc "Reads a scenario file."
  @spec load!(Path.t()) :: Scenario.t()
  def load!(path) do
    {value, _bindings} = Code.eval_file(path)

    unless Keyword.keyword?(value) do
      raise ArgumentError, "#{path} must end with a keyword list for Sim.Scenario.new/1"
    end

    Scenario.new(value)
  end

  @doc """
  A small mixed set: one big channel on weekday evenings, one mid-sized one
  most days, one tiny one, and one that never goes live. Enough for a
  tracker to have something to poll, something to miss, and something that
  stays offline.
  """
  @spec default() :: Scenario.t()
  def default do
    Scenario.new(
      seed: 7,
      channels: [
        [
          slug: "bigstreamer",
          peak_viewers: 18_000,
          language: "en",
          verified: true,
          subscribers: %{active: 4_200, gifted: 900, canceled: 310},
          schedule: %{days: [1, 2, 3, 4, 5], start_hour: 19, duration_min: 300}
        ],
        [
          slug: "midstreamer",
          peak_viewers: 600,
          language: "ar",
          subscribers: %{active: 72, gifted: 55, canceled: 8},
          schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 20, duration_min: 240}
        ],
        [
          slug: "smallstreamer",
          peak_viewers: 35,
          schedule: %{days: [6, 7], start_hour: 14, duration_min: 120}
        ],
        [slug: "quietstreamer", peak_viewers: 100, schedule: :never]
      ]
    )
  end
end
