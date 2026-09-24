defmodule Sim.Http.ControlTest do
  use ExUnit.Case, async: false

  alias Sim.{Clock, Instance, Scenario, Server, Webhooks}
  alias Sim.Pusher.Hub

  @monday_morning ~U[2026-01-05 10:00:00Z]

  # Receives webhooks and forwards each to the test process.
  defmodule Sink do
    @behaviour Plug
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      type = conn |> get_req_header("kick-event-type") |> List.first()
      send(test_pid, {:webhook, type, Jason.decode!(body)})
      send_resp(conn, 200, "")
    end
  end

  setup do
    scenario =
      Scenario.new(
        channels: [
          [slug: "somestreamer", schedule: %{days: [1], start_hour: 20, duration_min: 180}]
        ]
      )

    start_supervised!(
      {Instance,
       scenario: scenario, clock: Clock.new(sim_start: @monday_morning), port: 0, tick_ms: 0}
    )

    {:ok, sink} =
      Bandit.start_link(plug: {Sink, self()}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_, sink_port}} = ThousandIsland.listener_info(sink)
    Webhooks.put_webhook_url("http://127.0.0.1:#{sink_port}/")

    channel = Scenario.channel(scenario, "somestreamer")

    Webhooks.subscribe(
      channel.user_id,
      Enum.map(Webhooks.event_types(), &%{"name" => &1, "version" => 1})
    )

    %{base: Instance.base_url() <> "/_sim", channel: channel}
  end

  defp call(method, url, body \\ nil) do
    options = [method: method, url: url, retry: false]
    options = if body, do: Keyword.put(options, :json, body), else: options
    response = Req.request!(options)
    {response.status, response.body}
  end

  test "state shows the clock, channels, webhooks and Pusher", %{base: base} do
    {200, state} = call(:get, base <> "/state")

    assert state["now"] == "2026-01-05T10:00:00Z"

    assert [%{"slug" => "somestreamer", "live" => false, "next_start" => "2026-01-05T20:00:00Z"}] =
             state["channels"]

    assert state["webhooks"]["subscriptions"] == length(Webhooks.event_types())
    assert state["pusher"]["sockets"] == 0
  end

  test "going live and offline by hand delivers the webhooks before answering", %{base: base} do
    {200, live} = call(:post, base <> "/channels/somestreamer/live", %{"minutes" => 30})

    assert live["emitted"] == ["livestream.status.updated", "livestream.metadata.updated"]
    assert live["channel"]["live"] == true

    assert_receive {:webhook, "livestream.status.updated",
                    %{"is_live" => true, "started_at" => "2026-01-05T10:00:00Z"}},
                   2_000

    {200, offline} = call(:post, base <> "/channels/somestreamer/offline")
    assert offline["emitted"] == ["livestream.status.updated"]

    assert_receive {:webhook, "livestream.status.updated",
                    %{"is_live" => false, "ended_at" => "2026-01-05T10:00:00Z"}},
                   2_000

    assert {409, %{"error" => "not_live"}} = call(:post, base <> "/channels/somestreamer/offline")
  end

  test "moving the clock steps every channel, so a scheduled stream starts", %{base: base} do
    {200, moved} = call(:put, base <> "/clock", %{"at" => "2026-01-05T20:00:30Z"})

    assert moved["now"] == "2026-01-05T20:00:30Z"

    assert moved["emitted"]["somestreamer"] == [
             "livestream.status.updated",
             "livestream.metadata.updated"
           ]

    assert_receive {:webhook, "livestream.status.updated", %{"is_live" => true}}, 2_000

    {200, sped} = call(:put, base <> "/clock", %{"speed" => 60})
    assert sped["speed"] == 60

    assert {400, %{"error" => "bad_param: speed"}} =
             call(:put, base <> "/clock", %{"speed" => -1})

    assert {400, %{"error" => "bad_param: at"}} =
             call(:put, base <> "/clock", %{"at" => "tomorrow"})
  end

  test "title and category changes show in the API and arrive as metadata", %{base: base} do
    call(:post, base <> "/channels/somestreamer/live")
    assert_receive {:webhook, "livestream.metadata.updated", _}, 2_000

    {200, changed} =
      call(:post, base <> "/channels/somestreamer/metadata", %{
        "title" => "Big news",
        "category_id" => 15
      })

    assert changed["metadata"]["title"] == "Big news"

    assert_receive {:webhook, "livestream.metadata.updated",
                    %{"metadata" => %{"title" => "Big news", "category" => %{"id" => 15}}}},
                   2_000

    {200, state} = call(:get, base <> "/state")
    assert hd(state["channels"])["title"] == "Big news"

    assert {400, %{"error" => "unknown_category: 999"}} =
             call(:post, base <> "/channels/somestreamer/metadata", %{"category_id" => 999})
  end

  test "events on demand are delivered, each type as Kick names it", %{base: base} do
    {200, gift} =
      call(:post, base <> "/channels/somestreamer/events", %{"type" => "gift", "count" => 3})

    assert gift["event"] == "channel.subscription.gifts"
    assert_receive {:webhook, "channel.subscription.gifts", %{"giftees" => giftees}}, 2_000
    assert length(giftees) == 3

    {200, _} =
      call(:post, base <> "/channels/somestreamer/events", %{"type" => "kicks", "amount" => 500})

    assert_receive {:webhook, "kicks.gifted", %{"gift" => %{"amount" => 500}}}, 2_000

    assert {400, %{"error" => "missing: type"}} =
             call(:post, base <> "/channels/somestreamer/events", %{})

    assert {400, %{"error" => "unknown_event: raid"}} =
             call(:post, base <> "/channels/somestreamer/events", %{"type" => "raid"})

    assert {404, %{"error" => "unknown_channel"}} =
             call(:post, base <> "/channels/nobody/events", %{"type" => "follow"})
  end

  test "a chat message reaches Pusher subscribers and chat webhooks", %{
    base: base,
    channel: channel
  } do
    call(:post, base <> "/channels/somestreamer/live")
    topic = "chatrooms.#{channel.chatroom_id}.v2"
    :ok = Hub.join(topic)

    {200, sent} =
      call(:post, base <> "/channels/somestreamer/chat", %{"content" => "hello from the test"})

    assert sent["listening"] == true

    assert_receive {:pusher_frames, [frame]}, 2_000
    assert Jason.decode!(Jason.decode!(frame)["data"])["content"] == "hello from the test"
    assert_receive {:webhook, "chat.message.sent", %{"content" => "hello from the test"}}, 2_000
  end

  test "drop_next swallows the next deliveries, then delivery resumes", %{base: base} do
    {200, webhooks} = call(:put, base <> "/webhooks", %{"drop_next" => 2})
    assert webhooks["drop_next"] == 2

    for _ <- 1..3, do: call(:post, base <> "/channels/somestreamer/events", %{"type" => "follow"})

    assert_receive {:webhook, "channel.followed", _}, 2_000
    refute_receive {:webhook, "channel.followed", _}, 300

    {200, after_drops} = call(:get, base <> "/webhooks")
    assert after_drops["dropped"] == 2
    assert after_drops["drop_next"] == 0
  end

  test "faults can be set, cleared, and a typo is refused", %{base: base} do
    {200, set} = call(:put, base <> "/faults", %{"drop_webhooks" => 0.5})
    assert set["faults"] == %{"drop_webhooks" => 0.5}
    assert Scenario.fault(Server.scenario(), :drop_webhooks) == 0.5

    {200, cleared} = call(:put, base <> "/faults", %{})
    assert cleared["faults"] == %{}

    assert {400, %{"error" => "unknown_fault: drop_everything"}} =
             call(:put, base <> "/faults", %{"drop_everything" => 1})
  end

  test "expiring tokens makes the API ask for a new one", %{base: base} do
    token = Server.issue_token()
    assert Server.valid_token?(token)

    {200, _} = call(:post, base <> "/tokens/expire")
    refute Server.valid_token?(token)
  end

  test "disconnect closes every Pusher socket", %{base: base} do
    :ok = Hub.connected()
    {200, result} = call(:post, base <> "/pusher/disconnect")

    assert result["disconnected"] == 1
    assert_receive :fault_disconnect, 1_000
  end

  test "an unknown control is a 404", %{base: base} do
    assert {404, %{"error" => "no such control"}} = call(:get, base <> "/nope")
  end
end
