defmodule KickTrackerWeb.Admin.AdminPagesTest do
  use KickTrackerWeb.ConnCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures
  alias KickTracker.{Audit, Groups, Settings, TestBroker}

  setup :log_in_admin

  test "every admin page renders", %{conn: conn} do
    channel!(slug: "somestreamer")

    for path <-
          ~w(/admin/groups /admin/dead-letters /admin/data /admin/privacy /admin/chat-log /admin/settings /admin/audit) do
      assert {:ok, _view, html} = live(conn, path), path
      assert html =~ "Admin"
    end
  end

  test "settings are cast, saved and audited", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/settings")

    view
    |> form("#settings-form",
      settings: %{
        "sub_price_usd" => "3.5",
        "sub_share" => "0.5",
        "kick_value_usd" => "0.02",
        "support_page_public" => "false"
      }
    )
    |> render_submit()

    assert Settings.get("sub_price_usd") == 3.5
    assert Settings.get("support_page_public") == false
    assert [%{action: "settings.update"} | _] = Audit.recent()

    html =
      view |> form("#settings-form", settings: %{"sub_price_usd" => "lots"}) |> render_submit()

    assert html =~ "must be a number"
  end

  test "settings are saved all or none, and ranges are checked", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/settings")
    before = Audit.recent()

    # A good price with a share above 1: neither is stored, nothing audited.
    html =
      view
      |> form("#settings-form", settings: %{"sub_price_usd" => "9.99", "sub_share" => "1.5"})
      |> render_submit()

    assert html =~ "must be between 0 and 1"
    assert Settings.get("sub_price_usd") == 4.99
    assert Settings.get("sub_share") == 0.95
    assert Audit.recent() == before

    assert {:error, "kick_value_usd", _} =
             Settings.put_all(%{"sub_share" => "0.5", "kick_value_usd" => "-1"}, nil)

    assert {:error, "sub_price_usd", "must be a number"} =
             Settings.put_all(%{"sub_price_usd" => %{"x" => "1"}}, nil)

    assert {:error, "must be between 0 and 1000"} = Settings.put("sub_price_usd", "5000")
    assert Settings.get("sub_share") == 0.95

    assert {:ok, %{"sub_share" => 1.0}} = Settings.put_all(%{"sub_share" => "1"}, nil)
    assert [%{action: "settings.update", details: %{"sub_share" => 1.0}} | _] = Audit.recent()
  end

  test "groups are created, filled and made public", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    {:ok, view, _} = live(conn, ~p"/admin/groups")
    view |> form("#create-group", %{name: "Some group"}) |> render_submit()
    [g] = Groups.list()
    view |> form("#members-#{g.id}", %{channels: [c.id], public: "true"}) |> render_submit()
    assert [%{channel_ids: [id], public: true, slug: "some-group"}] = Groups.list(public: true)
    assert id == c.id
  end

  test "an exclusion from the data page queues the recomputation", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    s = stream!(c, ~U[2026-03-02 20:00:00Z], ~U[2026-03-02 21:00:00Z])
    {:ok, view, _} = live(conn, ~p"/admin/data?channel=#{c.id}")
    view |> element("#data-stream-#{s} form") |> render_submit(%{stream: s, note: "test stream"})
    assert_enqueued(worker: KickTracker.Workers.Reprocess, args: %{"stream_ids" => [s]})
    assert render(view) =~ "excluded"
  end

  test "annotations and reprocessing from the data page", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    {:ok, view, _} = live(conn, ~p"/admin/data?channel=#{c.id}")

    view
    |> form("#annotation-form",
      annotation: %{
        text: "collector outage",
        from_at: "2026-03-02T20:00",
        scope: "channel",
        public: "on"
      }
    )
    |> render_submit()

    assert [%{text: "collector outage", public: true}] = KickTracker.Annotations.list(c.id)

    view
    |> form("#reprocess-form",
      reprocess: %{kind: "rollups", from: "2026-03-02T00:00", to: "2026-03-03T00:00"}
    )
    |> render_submit()

    assert_enqueued(worker: KickTracker.Workers.Reprocess, args: %{"kind" => "rollups"})
  end

  test "a privacy request is found by username and confirmed by typing the id", %{conn: conn} do
    KickTracker.Repo.insert_all("kick_users", [
      %{id: 777, username: "someone", seen_at: DateTime.utc_now()}
    ])

    {:ok, view, _} = live(conn, ~p"/admin/privacy")
    view |> form("#find-user", %{q: "nobody_here"}) |> render_submit()
    html = view |> form("#find-user", %{q: "Someone"}) |> render_submit()
    assert html =~ "777"

    # The search is audited without what was searched for, found or not.
    assert [
             %{
               action: "privacy.find",
               target: nil,
               details: %{"by" => "username", "found" => true}
             },
             %{action: "privacy.find", target: nil, details: %{"found" => false}}
           ] = Audit.recent(2)

    refute inspect(Audit.recent()) =~ ~r/someone|nobody_here/i

    view |> form("#delete-user", %{confirm: "778"}) |> render_submit()
    refute_enqueued(worker: KickTracker.Workers.Privacy)

    view |> form("#delete-user", %{confirm: "777"}) |> render_submit()
    assert_enqueued(worker: KickTracker.Workers.Privacy, args: %{"user_id" => 777})
  end

  test "dead letters are listed and discarded with a reason", %{conn: conn} do
    TestBroker.purge()
    on_exit(&TestBroker.purge/0)
    {:ok, amqp} = AMQP.Connection.open(TestBroker.admin_url())
    {:ok, chan} = AMQP.Channel.open(amqp)

    AMQP.Basic.publish(chan, "kick.events.dlx", "channel.followed", "{}",
      message_id: "dead-1",
      type: "channel.followed"
    )

    AMQP.Connection.close(amqp)
    Process.sleep(100)

    {:ok, view, html} = live(conn, ~p"/admin/dead-letters")
    assert html =~ "dead-1"
    key = KickTracker.DeadLetters.key("dead-1", "{}")
    view |> element("#dl-#{key} button[phx-click=ask_discard]") |> render_click()
    view |> form("#discard-#{key}", %{reason: "garbage"}) |> render_submit()

    assert [
             %{
               action: "dead_letter.discard",
               target: "dead-1",
               details: %{"reason" => "garbage", "key" => ^key}
             }
             | _
           ] = Audit.recent()

    assert TestBroker.depth("kick_tracker.events.dead") == 0
  end

  test "a dead letter without a message id can be replayed", %{conn: conn} do
    TestBroker.purge()
    on_exit(&TestBroker.purge/0)
    {:ok, amqp} = AMQP.Connection.open(TestBroker.admin_url())
    {:ok, chan} = AMQP.Channel.open(amqp)
    AMQP.Basic.publish(chan, "kick.events.dlx", "channel.followed", "no id here")
    AMQP.Connection.close(amqp)
    Process.sleep(100)

    {:ok, view, html} = live(conn, ~p"/admin/dead-letters")
    assert html =~ "no message id"
    key = KickTracker.DeadLetters.key(nil, "no id here")
    view |> element("#dl-#{key} button[phx-click=replay]") |> render_click()

    assert [%{action: "dead_letter.replay", target: ^key} | _] = Audit.recent()
    assert TestBroker.depth("kick_tracker.events.dead") == 0
  end

  test "the audit log filters by action", %{conn: conn, admin: admin} do
    Audit.log(admin, "channel.pause", "somestreamer")
    Audit.log(admin, "channel.resume", "somestreamer")
    {:ok, _view, html} = live(conn, ~p"/admin/audit?action=channel.pause")
    assert html =~ "channel.pause"
    refute html =~ "channel.resume"
  end
end
