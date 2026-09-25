defmodule KickTrackerWeb.Admin.HealthLiveTest do
  use KickTrackerWeb.ConnCase

  import Phoenix.LiveViewTest
  alias KickTracker.{Fixtures, Health}
  alias KickTracker.Stats.Coverage

  setup :log_in_admin

  test "shows each channel's sources and coverage", %{conn: conn} do
    channel = Fixtures.channel!(slug: "somestreamer")
    now = DateTime.utc_now()
    # Polled fine for the last 30 minutes; chat failed a minute ago.
    for m <- 30..1//-1,
        do: Coverage.mark([channel.id], "api", true, DateTime.add(now, -m * 60), 150)

    Coverage.mark([channel.id], "chat", false, DateTime.add(now, -60), 150)

    [row] = Health.channels(now)
    assert row.poll.state == :ok
    assert row.chat.state == :failing
    assert_in_delta row.coverage.api_24h, 30 * 60 / 86_400, 0.001
    assert row.coverage.chat_24h == 0.0

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "somestreamer"
    assert html =~ "failing"
  end

  test "shows the collectors: who collects, who stands by, who is down, writes waiting", %{
    conn: conn
  } do
    now = DateTime.utc_now()

    for {id, state, ago, journal} <- [
          {"collector-a", "leader", 5, %{"depth" => 12, "oldest_at" => nil, "buried" => 0}},
          {"collector-b", "standby", 400, %{"depth" => 0, "oldest_at" => nil, "buried" => 1}}
        ] do
      KickTracker.Repo.query!(
        "INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status) VALUES ($1, $2, 1, $3, $3, $4)",
        [id, state, DateTime.add(now, -ago), %{"journal" => journal}]
      )
    end

    KickTracker.Repo.query!(
      "INSERT INTO collector_terms (name, epoch, holder, started_at) VALUES ('collector', 1, 'collector-a', $1)",
      [DateTime.add(now, -3600)]
    )

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "collector-a"
    assert html =~ "collecting"
    # Unheard of for over 90s: down, whatever its row says.
    assert html =~ "down"
    assert html =~ "Recent handoffs"
  end

  test "shows the build each collector runs, and marks one that differs from the site's", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    new = "5567775ded6214516af8765b9c57f4529550eb95"
    old = "320be38839bc023b674849567f7fbf7a42f4be9c"

    for {id, state, build} <- [
          {"collector-a", "leader", new},
          {"collector-b", "standby", old},
          # An image from before BUILD_SHA: unknown.
          {"collector-c", "standby", nil}
        ] do
      status = %{
        "journal" => %{"depth" => 0, "oldest_at" => nil, "buried" => 0},
        "build" => build
      }

      KickTracker.Repo.query!(
        "INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status) VALUES ($1, $2, 1, $3, $3, $4)",
        [id, state, now, status]
      )
    end

    assert [%{build: ^new}, %{build: ^old}, %{build: nil}] = Health.collectors()

    previous = Application.get_env(:kick_tracker, :build)
    Application.put_env(:kick_tracker, :build, new)
    on_exit(fn -> Application.put_env(:kick_tracker, :build, previous) end)

    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#collector-collector-a", "5567775")
    refute has_element?(view, "#collector-collector-a", "other build")
    assert has_element?(view, "#collector-collector-b", "320be38")
    assert has_element?(view, "#collector-collector-b", "other build")
    assert has_element?(view, "#collector-collector-c", "–")
    assert has_element?(view, "#web-build", "5567775")
  end

  test "a channel quarantined on a collector is named, with how often it crashed", %{conn: conn} do
    channel = Fixtures.channel!(slug: "somestreamer")
    now = DateTime.utc_now()

    status = %{
      "journal" => %{"depth" => 0, "oldest_at" => nil, "buried" => 0},
      "quarantined" => [
        %{
          "channel_id" => channel.id,
          "failures" => 3,
          "since" => DateTime.to_iso8601(DateTime.add(now, -120))
        }
      ]
    }

    KickTracker.Repo.query!(
      "INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status) VALUES ('collector-a', 'leader', 1, $1, $1, $2)",
      [now, status]
    )

    assert [%{quarantined: [%{channel_id: id, failures: 3}]}] = Health.collectors()
    assert id == channel.id

    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#quarantined-collector-a-#{channel.id}", "somestreamer")
    assert has_element?(view, "#quarantined-collector-a-#{channel.id}", "3 times in a row")
  end

  test "open alerts are listed first", %{conn: conn} do
    KickTracker.Repo.insert_all("alerts", [
      %{
        key: "dead_letters",
        message: "2 message(s) in the dead-letter queue",
        first_at: DateTime.utc_now(),
        last_at: DateTime.utc_now()
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Open alerts" and html =~ "dead-letter queue"
  end

  test "failed jobs are listed with how long ago they failed", %{conn: conn} do
    {:ok, job} = KickTracker.Workers.SubscriptionSync.new(%{}) |> Oban.insert()

    KickTracker.Repo.query!(
      "UPDATE oban_jobs SET state = 'retryable', attempted_at = now() at time zone 'utc' - interval '5 minutes', errors = ARRAY['{\"error\": \"Kick said no\"}'::jsonb] WHERE id = $1",
      [job.id]
    )

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Kick said no"
    assert html =~ "5m ago"
  end

  test "/healthz answers while the database does", %{conn: conn} do
    assert response(get(conn, "/healthz"), 200) == "ok"
  end

  test "a source that stopped reporting is stale, not ok" do
    channel = Fixtures.channel!()
    now = DateTime.utc_now()
    Coverage.mark([channel.id], "api", true, DateTime.add(now, -600), 150)
    assert [%{poll: %{state: :stale}, chat: %{state: :never}}] = Health.channels(now)
  end
end
