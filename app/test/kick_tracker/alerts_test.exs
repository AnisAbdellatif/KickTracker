defmodule KickTracker.AlertsTest do
  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Alerts
  alias KickTracker.Stats.Coverage

  setup do
    parent = self()
    %{notify: fn text, priority -> send(parent, {:notified, text, priority}) end}
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

    assert_received {:notified, "🔴 Kick's API isn't answering for somestreamer", :high}

    Alerts.run(DateTime.add(now, 60), notify)
    refute_received {:notified, "🔴 Kick's API" <> _, _}

    # Kick answers again.
    Coverage.mark([c.id], "api", true, DateTime.add(now, 90), 150)
    Alerts.run(DateTime.add(now, 120), notify)
    assert_received {:notified, "✅ resolved: Kick's API isn't answering for somestreamer", :low}
    refute Enum.any?(Alerts.open_alerts(), &(&1.key == key))
  end

  describe "notifying" do
    # Only the problems each test sets up: another test's message left in
    # the test broker's dead-letter queue would be one more.
    setup do
      url = Application.get_env(:kick_tracker, :dead_letters_amqp_url)
      Application.put_env(:kick_tracker, :dead_letters_amqp_url, nil)
      on_exit(fn -> Application.put_env(:kick_tracker, :dead_letters_amqp_url, url) end)
    end

    # Kick's API failing for `n` channels, tracked for too short a time
    # for the 24h coverage alert: each has only the one problem.
    defp failing_channels(n, now) do
      for i <- 1..n do
        c = channel!(slug: "somestreamer#{i}")

        Repo.query!("UPDATE channels SET tracked_since = $1 WHERE id = $2", [
          DateTime.add(now, -2, :hour),
          c.id
        ])

        Coverage.mark([c.id], "api", false, DateTime.add(now, -30), 150)
        Coverage.mark([c.id], "chat", true, DateTime.add(now, -30), 150)
        c
      end
    end

    test "a target that fails doesn't undo what was recorded, so nothing is sent twice", %{
      notify: notify
    } do
      now = DateTime.utc_now()
      failing_channels(1, now)

      # Before: notifying inside the transaction, a notifier that failed (or a
      # check killed at its time limit while ntfy answered 429) rolled the new
      # alert back, and the next minute sent it again.
      failing = fn _text, _priority -> raise "ntfy said 429" end
      assert_raise RuntimeError, fn -> Alerts.run(now, failing) end
      assert [%{key: "poll_failing:" <> _}] = Alerts.open_alerts()

      Alerts.run(DateTime.add(now, 60), notify)
      refute_received {:notified, _, _}
    end

    test "many problems of one kind at once go out as one message", %{notify: notify} do
      now = DateTime.utc_now()
      channels = failing_channels(12, now)

      Alerts.run(now, notify)
      assert_received {:notified, "🔴 12 new problems:\n" <> list, :high}
      assert list =~ "• Kick's API isn't answering for somestreamer"
      assert list =~ "…and 2 more"
      refute_received {:notified, _, _}

      for c <- channels, do: Coverage.mark([c.id], "api", true, DateTime.add(now, 90), 150)
      Alerts.run(DateTime.add(now, 120), notify)
      assert_received {:notified, "✅ 12 resolved:\n" <> _, :low}
      refute_received {:notified, _, _}
      assert Alerts.open_alerts() == []
    end

    test "a few problems are still sent one by one", %{notify: notify} do
      now = DateTime.utc_now()
      failing_channels(3, now)

      Alerts.run(now, notify)

      for _ <- 1..3,
          do:
            assert_received(
              {:notified, "🔴 Kick's API isn't answering for somestreamer" <> _, :high}
            )
    end
  end

  describe "the notifier" do
    setup do
      parent = self()

      plug = fn conn, _ ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        conn = Plug.Conn.fetch_query_params(conn)

        send(parent, {
          :posted,
          conn.request_path,
          conn.query_params,
          Plug.Conn.get_req_header(conn, "authorization"),
          body
        })

        Plug.Conn.send_resp(conn, 200, "{}")
      end

      {:ok, server} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Application.delete_env(:kick_tracker, :alerts) end)
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "posts to the configured webhook", %{base: base} do
      Application.put_env(:kick_tracker, :alerts, webhook_url: base <> "/hook")

      KickTracker.Alerts.Notifier.send("somestreamer is on fire")
      assert_received {:posted, "/hook", _, _, body}
      assert %{"content" => text, "text" => text} = Jason.decode!(body)
      assert text =~ "somestreamer is on fire"
    end

    test "publishes to the ntfy topic, with the priority and the token", %{base: base} do
      Application.put_env(:kick_tracker, :alerts,
        ntfy_url: base <> "/somestreamer-alerts",
        ntfy_token: "tk_1234567"
      )

      KickTracker.Alerts.Notifier.send("🔴 somestreamer is on fire", :high)

      assert_received {:posted, "/somestreamer-alerts", %{"priority" => "high", "title" => title},
                       ["Bearer tk_1234567"], "🔴 somestreamer is on fire"}

      assert title == KickTrackerWeb.Layouts.site_name()
    end

    test "publishes to an open ntfy topic without a token", %{base: base} do
      Application.put_env(:kick_tracker, :alerts, ntfy_url: base <> "/somestreamer-alerts")

      KickTracker.Alerts.Notifier.send("✅ resolved: somestreamer is on fire", :low)
      assert_received {:posted, "/somestreamer-alerts", %{"priority" => "low"}, [], _}
    end
  end
end
