defmodule KickTracker.Alerts.RulesTest do
  use ExUnit.Case, async: true

  alias KickTracker.Alerts.Rules

  @now ~U[2026-09-24 20:00:00Z]
  defp ago(s), do: DateTime.add(@now, -s)

  defp channel(attrs) do
    Map.merge(
      %{
        id: 1,
        slug: "somestreamer",
        active: true,
        tracked_since: ago(10 * 86_400),
        live_since: nil,
        poll_at: ago(30),
        poll_ok: true,
        chat_state: :ok,
        chat_at: ago(30),
        api_24h: 1.0
      },
      Map.new(attrs)
    )
  end

  defp snapshot(channels, attrs \\ []),
    do:
      Map.merge(
        %{
          channels: channels,
          last_webhook_at: ago(60),
          oldest_unprocessed_at: nil,
          clock_drift_s: 0.4,
          dead_letters: 0,
          queue_depth: 3
        },
        Map.new(attrs)
      )

  defp keys(snapshot), do: snapshot |> Rules.evaluate(@now) |> Enum.map(& &1.key) |> Enum.sort()

  test "a healthy collection raises nothing" do
    assert keys(snapshot([channel([])])) == []
  end

  test "a live channel without readings" do
    assert keys(snapshot([channel(live_since: ago(3600), poll_at: ago(400))])) == [
             "no_readings:1"
           ]

    # Just went live: not yet.
    assert keys(snapshot([channel(live_since: ago(120), poll_at: ago(400))])) == []
  end

  test "no webhooks while a channel has been live a while" do
    s = snapshot([channel(live_since: ago(3600))], last_webhook_at: ago(3 * 3600))
    assert keys(s) == ["no_webhooks"]
    # Offline channels send nothing: no alert.
    assert keys(snapshot([channel([])], last_webhook_at: ago(3 * 3600))) == []
  end

  test "chat down, failing polls, low coverage" do
    assert keys(snapshot([channel(chat_state: :stale, chat_at: ago(900))])) == ["chat_down:1"]

    assert keys(snapshot([channel(chat_state: :never, chat_at: nil, tracked_since: ago(600))])) ==
             []

    assert keys(snapshot([channel(poll_ok: false)])) == ["poll_failing:1"]
    assert keys(snapshot([channel(api_24h: 0.8)])) == ["coverage:1"]
    # Paused channels are left alone.
    assert keys(snapshot([channel(active: false, api_24h: 0.1, poll_ok: false)])) == []
  end

  test "dead letters, a consumer behind, a deep queue, clock drift" do
    s =
      snapshot([],
        dead_letters: 2,
        oldest_unprocessed_at: ago(3600),
        queue_depth: 5000,
        clock_drift_s: -95.0
      )

    assert keys(s) == ["clock_drift", "consumer_behind", "dead_letters", "queue_depth"]
    # Unknown (not configured) is not a problem.
    assert keys(snapshot([], dead_letters: nil, queue_depth: nil, clock_drift_s: nil)) == []
  end
end
