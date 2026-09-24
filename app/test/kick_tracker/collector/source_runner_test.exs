defmodule KickTracker.Collector.SourceRunnerTest do
  @moduledoc """
  What every source gets from the runner: coverage by outcome, effects,
  and isolation — a raising fetch, a hung fetch or a raising `record`
  fails that unit, never the runner.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Collector.{SourceRunner, Status}

  defmodule Fake do
    @moduledoc false
    @behaviour KickTracker.Collector.Source

    def name, do: :fake
    def coverage, do: {"api", 150}
    def init(opts), do: %{test: Keyword.fetch!(opts, :test)}
    def interval_ms(_), do: 60_000
    def limits(_), do: %{concurrency: 4, timeout_ms: 300}

    def units(channels, s, _now), do: {Enum.map(channels, &%{channels: [&1]}), s}

    # The channel's slug says how its fetch goes.
    def fetch(%{channels: [%{slug: "ok" <> _}]}), do: {:ok, 42}
    def fetch(%{channels: [%{slug: "raise" <> _}]}), do: raise("boom")
    def fetch(%{channels: [%{slug: "hang" <> _}]}), do: Process.sleep(:infinity)
    def fetch(%{channels: [%{slug: "odd" <> _}]}), do: :what
    def fetch(%{channels: [%{slug: "bad-record" <> _}]}), do: {:ok, :bad}

    def record(%{channels: [c]}, {:ok, :bad}, _at, _s), do: raise("record #{c.id}")

    def record(%{channels: [c]}, {:ok, n}, _at, s),
      do: {[], [{:broadcast, "fake-test", {:fetched, c.id, n}}], s}

    def record(_unit, {:error, _}, _at, s), do: {[], [], s}

    def finish(s, _at) do
      send(s.test, :finished)
      {[], [], s}
    end
  end

  setup do
    start_supervised!(Status)
    start_supervised!({Task.Supervisor, name: KickTracker.Collector.Tasks})
    Phoenix.PubSub.subscribe(KickTracker.PubSub, "fake-test")

    runner =
      start_supervised!({SourceRunner, {Fake, test: self(), first_ms: nil, name: :fake_runner}})

    %{runner: runner}
  end

  test "each unit's outcome is its coverage; failures of every kind stay contained", %{
    runner: runner
  } do
    ok = channel!(slug: "ok1")
    failures = for slug <- ~w(raise1 hang1 odd1), do: channel!(slug: slug)
    bad_record = channel!(slug: "bad-record1")

    :ok = SourceRunner.run_now(:fake_runner)
    assert_receive :finished
    assert_receive {:fetched, id, 42}
    assert id == ok.id
    assert Process.alive?(runner)

    coverage = rows("coverage", ["channel_id"]) |> Map.new(&{&1.channel_id, &1.ok})
    assert coverage[ok.id] == true
    for c <- failures, do: assert(coverage[c.id] == false)
    # The fetch worked, but what it meant couldn't be recorded (logged):
    # nothing was written for it, so it is no coverage at all, a gap.
    assert coverage[bad_record.id] == nil

    assert %{units: 5, failed: 3, cycle_at: %DateTime{}} = Status.get({:source, :fake})

    # And it keeps going.
    :ok = SourceRunner.run_now(:fake_runner)
    assert_receive :finished
  end

  test "a restarted runner keeps the cadence: its first cycle comes when the next was due" do
    start_supervised!(KickTracker.Collector.Journal)

    first_ms = fn name ->
      pid = start_supervised!({SourceRunner, {Fake, test: self(), name: name}}, id: name)
      Process.read_timer(:sys.get_state(pid).timer)
    end

    # Never ran here: soon.
    assert first_ms.(:fresh_runner) <= 1_000

    # Its last cycle started 10s ago (interval 60s): in about 50s, not at
    # once. Before, every restart polled at once, so a runner restarting
    # in a loop polled Kick every second or two.
    KickTracker.Collector.Journal.put(
      {:source_cycle, :fake},
      System.os_time(:millisecond) - 10_000
    )

    assert first_ms.(:restarted_runner) in 45_000..50_000
  end
end
