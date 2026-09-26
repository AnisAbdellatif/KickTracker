defmodule KickTrackerWeb.Admin.ChatLogLiveTest do
  @moduledoc "The chat log's admin page and export (project.md §12.8)."

  use KickTrackerWeb.ConnCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures
  alias KickTracker.{Audit, ChatLog}
  alias KickTrackerWeb.Admin.ChatLogController

  setup :log_in_admin

  @now ~U[2026-06-01 12:00:00.000000Z]

  defp logged!(channel, id, user, content, minutes_ago) do
    at = DateTime.add(@now, -minutes_ago, :minute)

    ChatLog.insert_messages(channel.id, [
      ChatLog.message_row(%{id: id, sender_id: user, at: at}, %{content: content, type: "message"})
    ])
  end

  test "turning logging on and off, and the retention, per channel; audited", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    {:ok, view, html} = live(conn, ~p"/admin/chat-log")
    assert html =~ "chat-log-settings"

    view |> element("#chat-log-toggle-#{c.id}") |> render_click()
    assert KickTracker.Repo.reload(c).chat_log

    view
    |> element("#chat-log-config-#{c.id}")
    |> render_change(%{"channel_id" => c.id, "days" => "30"})

    c = KickTracker.Repo.reload(c)
    assert {c.chat_log, c.chat_log_retention_days} == {true, 30}

    html =
      view
      |> element("#chat-log-config-#{c.id}")
      |> render_change(%{"channel_id" => c.id, "days" => "0"})

    assert html =~ "from 1 to"
    assert KickTracker.Repo.reload(c).chat_log_retention_days == 30

    assert [
             %{action: "chat_log.configure", details: %{"retention_days" => 30}},
             %{action: "chat_log.configure", details: %{"enabled" => true}} | _
           ] = Audit.recent()

    assert render(element(view, "#chat-log-summary")) =~ "1"
  end

  test "a long channel list is searched and filtered by logging", %{conn: conn} do
    for n <- 1..40, do: channel!(slug: "streamer#{n}")
    logged = channel!(slug: "somestreamer")
    {:ok, _} = ChatLog.configure(logged, true, 90)
    {:ok, view, _} = live(conn, ~p"/admin/chat-log")

    assert render(element(view, "#chat-log-settings-count")) =~ "41 of 41"

    view |> element("#chat-log-settings-search") |> render_change(%{"q" => "STREAMER1"})
    assert render(element(view, "#chat-log-settings-count")) =~ "11 of 41"
    refute has_element?(view, "#chat-log-channel-#{logged.id}")

    view |> element("#chat-log-settings-search") |> render_change(%{"q" => ""})
    view |> element("#chat-log-show-on") |> render_click()
    assert render(element(view, "#chat-log-settings-count")) =~ "1 of 41"
    assert has_element?(view, "#chat-log-channel-#{logged.id}")
  end

  test "the channel picker searches channels with a log and puts the choice in the URL",
       %{conn: conn} do
    a = channel!(slug: "somestreamer")
    b = channel!(slug: "otherstreamer")
    _never = channel!(slug: "quietstreamer")
    {:ok, _} = ChatLog.configure(a, true, 90)
    logged!(b, "b1", 7, "hello", 0)
    {:ok, view, _} = live(conn, ~p"/admin/chat-log")

    view |> element("#chat-log-picker-button") |> render_click()
    assert has_element?(view, "#chat-log-pick-#{a.id}")
    assert has_element?(view, "#chat-log-pick-#{b.id}")
    refute render(element(view, "#chat-log-picker")) =~ "quietstreamer"

    view |> element("#chat-log-picker-search") |> render_change(%{"q" => "other"})
    refute has_element?(view, "#chat-log-pick-#{a.id}")

    view |> element("#chat-log-pick-#{b.id}") |> render_click()
    assert_patch(view, ~p"/admin/chat-log?#{%{"channels" => "#{b.id}"}}")
    assert has_element?(view, "#chat-log-chips", "otherstreamer")
  end

  test "users and a preset period become chips; a chip removes its filter", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/chat-log")
    view |> form("#chat-log-user", %{"user" => "someone"}) |> render_submit()
    assert_patch(view, ~p"/admin/chat-log?#{%{"users" => "someone"}}")

    view |> element("#chat-log-period-7d") |> render_click()
    assert_patch(view, ~p"/admin/chat-log?#{%{"period" => "7d", "users" => "someone"}}")
    assert has_element?(view, "#chat-log-chips", "last 7d")

    view |> element("#chat-log-chips a", "someone") |> render_click()
    assert_patch(view, ~p"/admin/chat-log?#{%{"period" => "7d"}}")
  end

  test "a user's history across channels, text escaped; the audit says a user was looked up, not whom",
       %{conn: conn} do
    a = channel!(slug: "somestreamer")
    b = channel!(slug: "otherstreamer")
    KickTracker.Repo.insert_all("kick_users", [%{id: 7, username: "someone", seen_at: @now}])
    logged!(a, "a1", 7, "<b>on a</b>", 2)
    logged!(b, "b1", 7, "on b", 1)
    logged!(a, "a2", 8, "someone else", 0)

    {:ok, _view, html} = live(conn, ~p"/admin/chat-log?users=someone")
    assert html =~ "somestreamer" and html =~ "otherstreamer"
    assert html =~ "&lt;b&gt;on a&lt;/b&gt;"
    assert html =~ "on b"
    refute html =~ "someone else"

    assert [%{action: "chat_log.view", target: nil, details: details} | _] = Audit.recent()
    assert details["by_user"] == true
    refute inspect(details) =~ "someone"

    {:ok, _view, html} = live(conn, ~p"/admin/chat-log?channels=#{a.id}")
    assert html =~ "someone else"
    refute html =~ "on b"
  end

  test "deleting a period: a dialog that starts from the view, checked, then the collector's job; audited",
       %{conn: conn} do
    c = channel!(slug: "somestreamer")

    {:ok, view, _} =
      live(conn, ~p"/admin/chat-log?#{%{"channels" => c.id, "from" => "2026-06-01T10:00"}}")

    view |> element("#chat-log-ask-delete") |> render_click()
    assert has_element?(view, "#chat-log-delete input[name='d[slug]'][value='somestreamer']")

    period = %{slug: "somestreamer", from: "2026-06-01T10:00", to: "2026-06-01T11:00"}

    html = view |> form("#chat-log-delete", d: period) |> render_submit()
    assert html =~ "deleted for good"
    refute_enqueued(worker: KickTracker.Workers.ChatLog)

    html =
      view |> form("#chat-log-delete", d: %{period | slug: "nosuchstreamer"}) |> render_submit()

    assert html =~ "No channel with that slug"

    view
    |> form("#chat-log-delete", d: Map.put(period, :understood, "true"))
    |> render_submit()

    assert_enqueued(
      worker: KickTracker.Workers.ChatLog,
      args: %{
        "channel_id" => c.id,
        "from" => "2026-06-01T10:00:00Z",
        "to" => "2026-06-01T11:00:00Z"
      }
    )

    refute has_element?(view, "#chat-log-delete-dialog")
    assert [%{action: "chat_log.delete", target: "somestreamer"} | _] = Audit.recent()
  end

  test "the export is the filtered log as CSV, oldest first; audited", %{conn: conn} do
    a = channel!(slug: "somestreamer")
    b = channel!(slug: "otherstreamer")
    logged!(a, "a1", 7, "hello, \"you\"", 2)
    logged!(a, "a2", 7, "=1+1", 1)
    logged!(b, "b1", 7, "not selected", 0)

    conn = get(conn, ~p"/admin/chat-log/export.csv?#{%{"channels" => a.id}}")
    assert response_content_type(conn, :csv) =~ "text/csv"
    [header, first, second, ""] = String.split(response(conn, 200), "\r\n")

    assert header ==
             "sent_at,channel,user_id,username,type,message_id,reply_to_message_id,reply_to_user_id,content"

    assert first =~ ~s(,a1,,,"hello, ""you""")
    assert second =~ ",a2,,,'=1+1"
    assert [%{action: "chat_log.export"} | _] = Audit.recent()
  end

  test "a CSV line quotes what needs it and defuses formulas" do
    assert IO.iodata_to_binary(ChatLogController.line(["a", 1, nil, "b\nc", "@x", "-2"])) ==
             ~s(a,1,,"b\nc",'@x,'-2\r\n)
  end

  test "none of it without an admin" do
    conn = build_conn()
    assert redirected_to(get(conn, ~p"/admin/chat-log/export.csv")) =~ "/admin/login"
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/chat-log")
    assert to =~ "/admin/login"
  end
end
