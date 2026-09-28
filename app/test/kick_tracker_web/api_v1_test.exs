defmodule KickTrackerWeb.ApiV1Test do
  @moduledoc """
  The public read API (project.md §13.10): a key issued by an admin, what
  it reaches (channels, visibility, scopes), its limits, and admin keys.
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import KickTracker.Fixtures

  alias KickTracker.{ApiKeys, Groups, Repo}

  setup do
    KickTracker.Cache.clear()
    now = DateTime.utc_now()
    started = DateTime.add(now, -2 * 3600)

    public = channel!(slug: "somestreamer")
    other = channel!(slug: "otherstreamer")
    live_only = channel!(slug: "liveonlystreamer", visibility: :live_only)
    hidden = channel!(slug: "hiddenstreamer", visibility: :hidden)

    streams =
      for c <- [public, other, live_only, hidden], into: %{} do
        s = stream!(c, started)
        samples!(c, s, for(m <- 1..119, do: {DateTime.add(started, m * 60), 100 + m}))
        covered!(c, "api", started, DateTime.add(now, 60))
        {c.slug, s}
      end

    {:ok, g} = Groups.create("Some group", false)
    Groups.set_members(g, [other.id])

    # The API needs no page token: a conn without one.
    conn = delete_req_header(build_conn(), "x-data-token")

    %{conn: conn, public: public, other: other, hidden: hidden, streams: streams, group: g}
  end

  defp key!(attrs) do
    {:ok, key, raw} = ApiKeys.create(nil, Map.merge(%{name: "some app"}, Map.new(attrs)))
    {key, raw}
  end

  defp api(conn, raw, path),
    do: conn |> put_req_header("authorization", "Bearer " <> raw) |> get("/api/v1" <> path)

  defp slugs(body), do: body["channels"] |> Enum.map(& &1["slug"]) |> Enum.sort()

  describe "keys" do
    test "without a valid key: 401", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_key"}} =
               json_response(get(conn, "/api/v1/channels"), 401)

      assert json_response(api(conn, "kt_nope", "/channels"), 401)

      {_key, raw} = key!(scopes: ~w(channels))
      # A key in the URL isn't read (it would end up in logs).
      assert json_response(get(conn, "/api/v1/channels?key=#{raw}"), 401)

      assert json_response(
               conn
               |> put_req_header("authorization", "bearer " <> raw)
               |> get("/api/v1/channels"),
               200
             )
    end

    test "a revoked or expired key stops working; use is recorded", %{conn: conn} do
      {key, raw} = key!(scopes: ~w(channels))
      assert json_response(api(conn, raw, "/channels"), 200)
      assert ApiKeys.get!(key.id).last_used_at

      {:ok, _} = ApiKeys.revoke(key)
      assert json_response(api(conn, raw, "/channels"), 401)

      {key, raw} = key!(scopes: ~w(channels))
      {:ok, _} = ApiKeys.update(key, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      assert json_response(api(conn, raw, "/channels"), 401)
    end

    test "a key limited to addresses works only from them", %{conn: conn} do
      {_key, raw} = key!(scopes: ~w(channels), allowed_cidrs: ["203.0.113.0/24"])
      assert json_response(api(%{conn | remote_ip: {198, 51, 100, 7}}, raw, "/channels"), 401)
      assert json_response(api(%{conn | remote_ip: {203, 0, 113, 9}}, raw, "/channels"), 200)
    end

    test "each key has its own rate limit; requests without a key are limited by address", %{
      conn: conn
    } do
      previous = Application.get_env(:kick_tracker, :rate_limits)
      Application.put_env(:kick_tracker, :rate_limits, api: 2)
      on_exit(fn -> Application.put_env(:kick_tracker, :rate_limits, previous) end)

      {_key, raw} = key!(scopes: ~w(channels), rate_limit: 2)
      {_key, other} = key!(scopes: ~w(channels), rate_limit: 5)
      ip = {203, 0, 113, System.unique_integer([:positive]) |> rem(250)}
      conn = %{conn | remote_ip: ip}

      assert api(conn, raw, "/channels").status == 200
      assert api(conn, raw, "/channels").status == 200
      assert api(conn, raw, "/channels").status == 429
      # Another key from the same address counts on its own.
      assert api(conn, other, "/channels").status == 200

      assert get(conn, "/api/v1/channels").status == 401
      assert get(conn, "/api/v1/channels").status == 401
      assert get(conn, "/api/v1/channels").status == 429

      # A shared key counts per address: each of its users gets the limit.
      {_key, shared} = key!(scopes: ~w(channels), rate_limit: 2, per_address: true)
      assert api(conn, shared, "/channels").status == 200
      assert api(conn, shared, "/channels").status == 200
      assert api(conn, shared, "/channels").status == 429

      elsewhere = %{
        conn
        | remote_ip: {198, 51, 100, System.unique_integer([:positive]) |> rem(250)}
      }

      assert api(elsewhere, shared, "/channels").status == 200
    end
  end

  describe "channels a key reaches" do
    test "every channel: public ones fully, live-only ones live, hidden ones never", %{
      conn: conn
    } do
      {_key, raw} = key!(scopes: ~w(channels live viewers))
      body = json_response(api(conn, raw, "/channels"), 200)
      assert slugs(body) == ~w(liveonlystreamer otherstreamer somestreamer)

      by_slug = Map.new(body["channels"], &{&1["slug"], &1})
      assert %{"access" => "full", "live" => true, "tracked_since" => _} = by_slug["somestreamer"]
      assert by_slug["somestreamer"]["scopes"] == ~w(channels live viewers)
      assert %{"access" => "live", "scopes" => ["live"]} = by_slug["liveonlystreamer"]
      refute Map.has_key?(by_slug["liveonlystreamer"], "tracked_since")
      refute Map.has_key?(by_slug["somestreamer"], "visibility")

      assert json_response(api(conn, raw, "/channels/hiddenstreamer"), 404)
      assert json_response(api(conn, raw, "/channels/hiddenstreamer/viewers"), 404)
    end

    test "chosen channels and groups; others are 404, like channels that don't exist", %{
      conn: conn,
      group: g,
      public: public,
      hidden: hidden
    } do
      {_key, raw} =
        key!(
          scopes: ~w(channels viewers),
          all_channels: false,
          channel_ids: [public.id, hidden.id],
          group_ids: [g]
        )

      assert slugs(json_response(api(conn, raw, "/channels"), 200)) ==
               ~w(otherstreamer somestreamer)

      assert json_response(api(conn, raw, "/channels/otherstreamer/viewers?period=24h"), 200)

      assert %{"error" => %{"code" => "not_found"}} =
               json_response(api(conn, raw, "/channels/liveonlystreamer/now"), 404)

      assert json_response(api(conn, raw, "/channels/hiddenstreamer/viewers"), 404)
    end

    test "a live-only channel gives only now", %{conn: conn, streams: streams} do
      {_key, raw} = key!(scopes: ~w(channels live viewers chat))
      now = json_response(api(conn, raw, "/channels/liveonlystreamer/now"), 200)
      # No chat coverage: active chatters unknown, not 0.
      assert %{"live" => true, "viewers" => 219, "active_chatters" => nil} = now
      refute Map.has_key?(now, "title")
      refute Map.has_key?(now, "started_at")

      assert %{"error" => %{"code" => "out_of_scope"}} =
               json_response(api(conn, raw, "/channels/liveonlystreamer/viewers"), 403)

      assert json_response(api(conn, raw, "/channels/liveonlystreamer/streams"), 403)
      assert json_response(api(conn, raw, "/streams/#{streams["liveonlystreamer"]}"), 404)

      live = json_response(api(conn, raw, "/live"), 200)
      assert slugs(live) == ~w(liveonlystreamer otherstreamer somestreamer)
    end
  end

  describe "data" do
    test "only the kinds of data the key's scopes name", %{conn: conn} do
      {_key, raw} = key!(scopes: ~w(channels viewers))

      assert %{"res" => _, "t" => [_ | _], "avg" => _, "from" => _, "clamped" => false} =
               json_response(api(conn, raw, "/channels/somestreamer/viewers?period=24h"), 200)

      assert json_response(api(conn, raw, "/channels/somestreamer/heatmap?period=7d"), 200)

      for s <- ~w(chat followers support categories) do
        assert %{"error" => %{"code" => "out_of_scope"}} =
                 json_response(api(conn, raw, "/channels/somestreamer/#{s}"), 403)
      end

      assert json_response(api(conn, raw, "/channels/somestreamer/nonsense"), 404)
      assert json_response(api(conn, raw, "/channels/somestreamer/now"), 403)

      [row] = json_response(api(conn, raw, "/channels/somestreamer/streams"), 200)["streams"]
      # Figures come from the rollup (not run here): unknown, and there.
      assert %{"id" => _, "started_at" => _, "avg_viewers" => nil, "peak_viewers" => nil} = row
      refute Map.has_key?(row, "messages")
      refute Map.has_key?(row, "subs")
    end

    test "a stream: its timeline, and the series the scopes name", %{
      conn: conn,
      streams: streams
    } do
      id = streams["somestreamer"]
      {_key, raw} = key!(scopes: ~w(channels viewers chat))
      body = json_response(api(conn, raw, "/streams/#{id}"), 200)
      assert %{"stream" => %{"id" => ^id, "live" => true}, "viewers" => _, "chat" => _} = body
      refute Map.has_key?(body, "support")
      assert json_response(api(conn, raw, "/streams/#{id}/chatters?window=5"), 200)["chatters"]

      {_key, raw} = key!(scopes: ~w(viewers))
      assert json_response(api(conn, raw, "/streams/#{id}"), 403)
      assert json_response(api(conn, raw, "/streams/#{streams["hiddenstreamer"]}"), 404)
    end

    test "from narrows a stream to what came since, for a client following it live", %{
      conn: conn,
      public: public,
      streams: streams
    } do
      id = streams["somestreamer"]
      now = DateTime.utc_now()

      Repo.insert_all("channel_events", [
        %{
          channel_id: public.id,
          occurred_at: DateTime.add(now, -3600),
          kind: "hosted_by",
          other_channel: "otherstreamer",
          viewers: 50,
          dedup_key: "h1",
          payload: %{}
        },
        %{
          channel_id: public.id,
          occurred_at: DateTime.add(now, -300),
          kind: "hosted_by",
          other_channel: "otherstreamer",
          viewers: 80,
          dedup_key: "h2",
          payload: %{}
        }
      ])

      {_key, raw} = key!(scopes: ~w(channels viewers chat))
      from = DateTime.to_unix(now) - 15 * 60

      all = json_response(api(conn, raw, "/streams/#{id}"), 200)
      assert length(all["markers"]) == 2
      assert length(all["viewers"]["t"]) > 100

      recent = json_response(api(conn, raw, "/streams/#{id}?from=#{from}"), 200)
      assert recent["from"] == from
      assert Enum.all?(recent["viewers"]["t"], &(&1 >= from))
      assert length(recent["viewers"]["t"]) in 13..16

      assert [%{"kind" => "hosted_by", "other" => "otherstreamer", "value" => 80}] =
               recent["markers"]

      chatters =
        json_response(api(conn, raw, "/streams/#{id}/chatters?window=5&from=#{from}"), 200)

      assert length(chatters["t"]) in 14..16
      assert Enum.all?(chatters["t"], &(&1 >= div(from, 60) * 60))

      # A from before the stream, or not a time, changes nothing.
      assert json_response(api(conn, raw, "/streams/#{id}?from=0"), 200)["viewers"] ==
               all["viewers"]

      assert json_response(api(conn, raw, "/streams/#{id}?from=soon"), 200)["viewers"] ==
               all["viewers"]
    end

    test "history and resolution are held to the key's limits", %{conn: conn, streams: streams} do
      {_key, raw} = key!(scopes: ~w(channels viewers chat), history_days: 1, min_res: "1h")

      body = json_response(api(conn, raw, "/channels/somestreamer/viewers?period=30d"), 200)
      assert body["clamped"] == true
      assert_in_delta body["from"], DateTime.to_unix(DateTime.utc_now()) - 86_400, 120
      assert body["res"] == "1h"

      body =
        json_response(api(conn, raw, "/channels/somestreamer/viewers?period=24h&res=raw"), 200)

      assert body["clamped"] == false
      assert body["res"] == "1h"

      assert %{"error" => %{"code" => "resolution"}} =
               json_response(api(conn, raw, "/streams/#{streams["somestreamer"]}/chatters"), 403)
    end
  end

  describe "admin keys" do
    test "reach hidden channels and logged chat, a page at a time", %{
      conn: conn,
      hidden: hidden
    } do
      at = DateTime.add(DateTime.utc_now(), -600)

      Repo.insert_all(
        "chat_messages",
        for i <- 1..5 do
          %{
            channel_id: hidden.id,
            sent_at: DateTime.add(at, i),
            message_id: "m#{i}",
            user_id: 1_234_567,
            content: "hello #{i}"
          }
        end
      )

      Repo.insert_all("chat_log_events", [
        %{channel_id: hidden.id, occurred_at: at, event: "pinned", payload: %{}, dedup_key: "p1"}
      ])

      {_key, admin} = key!(admin: true)
      body = json_response(api(conn, admin, "/channels"), 200)
      assert "hiddenstreamer" in slugs(body)

      assert %{"visibility" => "hidden", "access" => "full"} =
               Enum.find(body["channels"], &(&1["slug"] == "hiddenstreamer"))

      assert json_response(api(conn, admin, "/channels/hiddenstreamer/viewers?period=24h"), 200)

      page =
        json_response(api(conn, admin, "/channels/hiddenstreamer/chat-log/messages?limit=3"), 200)

      assert Enum.map(page["messages"], & &1["content"]) == ["hello 5", "hello 4", "hello 3"]
      assert page["next"]

      rest =
        json_response(
          api(
            conn,
            admin,
            "/channels/hiddenstreamer/chat-log/messages?limit=3&before=#{page["next"]}"
          ),
          200
        )

      assert Enum.map(rest["messages"], & &1["content"]) == ["hello 2", "hello 1"]
      assert rest["next"] == nil

      assert [%{"event" => "pinned"}] =
               json_response(api(conn, admin, "/channels/hiddenstreamer/chat-log/events"), 200)[
                 "events"
               ]

      {_key, regular} = key!(scopes: KickTracker.ApiKeys.Access.scopes())

      assert %{"error" => %{"code" => "out_of_scope"}} =
               json_response(api(conn, regular, "/channels/somestreamer/chat-log/messages"), 403)
    end
  end
end
