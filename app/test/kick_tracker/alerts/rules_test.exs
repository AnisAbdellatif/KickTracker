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

  test "a payload that changed shape" do
    issue = %{
      event_type: "kicks.gifted",
      event_version: "1",
      problem: "gift.amount is not an integer",
      count: 3
    }

    assert keys(snapshot([], payload_issues: [issue])) == [
             "payload:kicks.gifted:1:gift.amount is not an integer"
           ]
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

  defp collector(id, attrs) do
    Map.merge(
      %{
        id: id,
        state: "standby",
        heartbeat_at: ago(5),
        journal_depth: 0,
        journal_oldest_at: nil,
        journal_buried: 0,
        quarantined: []
      },
      Map.new(attrs)
    )
  end

  test "the collectors: one leading and one standing by raises nothing" do
    assert keys(snapshot([], collectors: [collector("a", state: "leader"), collector("b", [])])) ==
             []

    # A site that never had a collector report says nothing about them.
    assert keys(snapshot([], collectors: [])) == []
  end

  test "no collector collecting, and a lost standby" do
    # The leader stopped reporting: nobody collects, and no failover left.
    s =
      snapshot([],
        collectors: [collector("a", state: "leader", heartbeat_at: ago(600)), collector("b", [])]
      )

    assert keys(s) == ["no_collector", "no_standby"]

    # A cleanly stopped leader whose standby hasn't taken over yet.
    s = snapshot([], collectors: [collector("a", state: "stopped"), collector("b", [])])
    assert keys(s) == ["no_collector"]
  end

  test "writes waiting for the database, and writes set aside" do
    s =
      snapshot([],
        collectors: [
          collector("a", state: "leader", journal_depth: 900, journal_oldest_at: ago(900)),
          collector("b", journal_buried: 2)
        ]
      )

    assert keys(s) == ["journal_behind:a", "journal_buried:b"]
  end

  test "the collectors: a channel whose processes kept crashing is an alert" do
    q = [%{channel_id: 42, failures: 3, since: ago(120)}]

    s = snapshot([], collectors: [collector("a", state: "leader", quarantined: q)])

    assert keys(s) == ["quarantined:a"]
  end

  test "the shadow: seen recently is fine; unseen for 15 minutes is an alert, apart from the collectors" do
    ok = [
      collector("a", state: "leader"),
      collector("shadow", state: "shadow", heartbeat_at: ago(400))
    ]

    assert keys(snapshot([], collectors: ok)) == []

    gone = [
      collector("a", state: "leader"),
      collector("shadow", state: "shadow", heartbeat_at: ago(1200))
    ]

    # A missing shadow is not a missing standby.
    assert keys(snapshot([], collectors: gone)) == ["shadow_down"]
  end
end
