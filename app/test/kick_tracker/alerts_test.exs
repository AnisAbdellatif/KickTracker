defmodule KickTracker.AlertsTest do
  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Alerts
  alias KickTracker.Stats.Coverage

  setup do
    parent = self()
    %{notify: fn text -> send(parent, {:notified, text}) end}
  end

  test "a problem is notified when it starts and when it ends, not every minute", %{
    notify: notify
  } do
    c = channel!(slug: "somestreamer")
    now = DateTime.utc_now()

    Repo.query!("UPDATE channels SET tracked_since = $1 WHERE id = $2", [
      DateTime.add(now, -2, :day),
      c.id
    ])

    Coverage.mark([c.id], "api", false, DateTime.add(now, -30), 150)
    Coverage.mark([c.id], "chat", true, DateTime.add(now, -30), 150)

    assert [%{key: key}] =
             Alerts.run(now, notify) |> Enum.filter(&String.starts_with?(&1.key, "poll_failing"))

    assert_received {:notified, "🔴 Kick's API isn't answering for somestreamer"}

    Alerts.run(DateTime.add(now, 60), notify)
    refute_received {:notified, "🔴 Kick's API" <> _}

    # Kick answers again.
    Coverage.mark([c.id], "api", true, DateTime.add(now, 90), 150)
    Alerts.run(DateTime.add(now, 120), notify)
    assert_received {:notified, "✅ resolved: Kick's API isn't answering for somestreamer"}
    refute Enum.any?(Alerts.open_alerts(), &(&1.key == key))
  end

  test "the notifier posts to the configured webhook" do
    parent = self()

    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:posted, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 204, "")
    end

    {:ok, server} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:kick_tracker, :alerts, webhook_url: "http://127.0.0.1:#{port}/hook")
    on_exit(fn -> Application.delete_env(:kick_tracker, :alerts) end)

    KickTracker.Alerts.Notifier.send("somestreamer is on fire")
    assert_received {:posted, %{"content" => text, "text" => text}}
    assert text =~ "somestreamer is on fire"
  end
end
