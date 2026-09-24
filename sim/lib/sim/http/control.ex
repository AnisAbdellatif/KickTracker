defmodule Sim.Http.Control do
  @moduledoc """
  The simulator's control API, under `/_sim`, for driving a running fake
  Kick by hand or from tests. It is not part of Kick, and serves on the same
  loopback-only port as the rest of the simulator.

      GET  /_sim/state                        clock, channels, webhooks, Pusher
      PUT  /_sim/clock        {at?, speed?, advance_s?}
      POST /_sim/channels/:slug/live          {minutes?}
      POST /_sim/channels/:slug/offline
      POST /_sim/channels/:slug/metadata      {title?, category_id?}
      POST /_sim/channels/:slug/events        {type, user_id?, count?, amount?, months?, anonymous?, permanent?}
      POST /_sim/channels/:slug/chat          {content, sender_id?}
      GET  /_sim/webhooks
      PUT  /_sim/webhooks     {url?, drop_next?}
      PUT  /_sim/faults       {drop_webhooks?, duplicate_webhooks?, pusher_disconnect_after_s?}
      POST /_sim/pusher/disconnect
      POST /_sim/tokens/expire

  Changes to a channel take effect at once: the channel's process is
  stepped immediately, so the events a change causes (a stream starting or
  ending) are emitted before the call returns, and the answer lists them
  under `emitted`. Emitted is not delivered: with no webhook URL or no
  subscription, nothing is sent (`GET /_sim/webhooks` shows what was).
  """

  use Plug.Router

  alias Sim.Channel.Server, as: ChannelServer
  alias Sim.{Channels, Clock, Control, Payloads, Scenario, Schedule, Server, Webhooks}
  alias Sim.Pusher.{Hub, Socket}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  get "/state" do
    json(conn, 200, state())
  end

  put "/clock" do
    params = conn.body_params
    clock = Server.clock()
    now = Server.now()

    result =
      with {:ok, at} <- target_time(params, now),
           {:ok, speed} <- speed(params, clock.speed) do
        {:ok, Clock.new(sim_start: at, speed: speed)}
      end

    case result do
      {:ok, clock} ->
        Server.put_clock(clock)
        stepped = step_all()

        json(conn, 200, %{
          "now" => Payloads.iso(Server.now()),
          "speed" => clock.speed,
          "emitted" => stepped
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  post "/channels/:slug/live" do
    minutes = Map.get(conn.body_params, "minutes", 120)
    change(conn, slug, &Control.go_live(&1, slug, &2, minutes))
  end

  post "/channels/:slug/offline" do
    change(conn, slug, &Control.go_offline(&1, slug, &2))
  end

  post "/channels/:slug/metadata" do
    now = Server.now()

    case Control.set_metadata(Server.scenario(), slug, now, conn.body_params) do
      {:ok, scenario} ->
        Server.put_scenario(scenario)
        channel = Scenario.channel(scenario, slug)
        window = Schedule.stream_at(channel, now)
        body = Payloads.metadata_updated(channel, window, now)
        Webhooks.deliver(channel.user_id, "livestream.metadata.updated", body, now)

        json(conn, 200, %{
          "emitted" => ["livestream.metadata.updated"],
          "metadata" => body["metadata"]
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  post "/channels/:slug/events" do
    now = Server.now()
    params = conn.body_params

    with {:ok, type} <- required(params, "type"),
         {:ok, {event, body}} <- Control.event(Server.scenario(), slug, type, params, now) do
      channel = Scenario.channel(Server.scenario(), slug)
      result = Webhooks.deliver(channel.user_id, event, body, now)
      json(conn, 200, %{"event" => event, "delivery" => to_string(result), "body" => body})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  post "/channels/:slug/chat" do
    now = Server.now()
    params = conn.body_params

    case Control.chat(Server.scenario(), slug, params["content"], params["sender_id"], now) do
      {:ok, {channel, message}} ->
        topic = "chatrooms.#{channel.chatroom_id}.v2"
        data = channel |> Payloads.chat_message(message) |> Jason.encode!()
        Hub.broadcast(topic, [Socket.frame("App\\Events\\ChatMessageEvent", data, topic)])

        Webhooks.deliver(
          channel.user_id,
          "chat.message.sent",
          Payloads.chat_message_sent(channel, message),
          now
        )

        json(conn, 200, %{
          "topic" => topic,
          "listening" => Hub.listened?(topic),
          "id" => message.id
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  get "/webhooks" do
    json(conn, 200, webhooks())
  end

  put "/webhooks" do
    params = conn.body_params

    cond do
      Map.has_key?(params, "drop_next") and
          not (is_integer(params["drop_next"]) and params["drop_next"] >= 0) ->
        error(conn, {:bad_param, "drop_next"})

      true ->
        if Map.has_key?(params, "url"), do: Webhooks.put_webhook_url(params["url"])
        if Map.has_key?(params, "drop_next"), do: Webhooks.drop_next(params["drop_next"])
        json(conn, 200, webhooks())
    end
  end

  put "/faults" do
    case Control.set_faults(Server.scenario(), conn.body_params) do
      {:ok, scenario} ->
        Server.put_scenario(scenario)
        json(conn, 200, %{"faults" => scenario.faults})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  post "/pusher/disconnect" do
    json(conn, 200, %{"disconnected" => Hub.disconnect_all()})
  end

  post "/tokens/expire" do
    Server.expire_tokens()
    json(conn, 200, %{"expired" => true})
  end

  match _ do
    json(conn, 404, %{"error" => "no such control"})
  end

  # Applies a change to one channel, then steps that channel at once so
  # whatever it causes is emitted before the answer.
  defp change(conn, slug, fun) do
    case fun.(Server.scenario(), Server.now()) do
      {:ok, scenario} ->
        Server.put_scenario(scenario)
        emitted = if ChannelServer.whereis(slug), do: ChannelServer.tick(slug), else: []

        json(conn, 200, %{
          "emitted" => emitted,
          "channel" => channel_state(Scenario.channel(scenario, slug))
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp step_all do
    Map.new(Channels.running(), fn slug -> {slug, ChannelServer.tick(slug)} end)
  end

  defp target_time(%{"at" => at}, _now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> {:ok, at}
      _ -> {:error, {:bad_param, "at"}}
    end
  end

  defp target_time(%{"advance_s" => s}, now) when is_number(s) and s >= 0,
    do: {:ok, DateTime.add(now, round(s * 1000), :millisecond)}

  defp target_time(%{"advance_s" => _}, _now), do: {:error, {:bad_param, "advance_s"}}
  defp target_time(_params, now), do: {:ok, now}

  defp speed(%{"speed" => speed}, _current) when is_number(speed) and speed > 0, do: {:ok, speed}
  defp speed(%{"speed" => _}, _current), do: {:error, {:bad_param, "speed"}}
  defp speed(_params, current), do: {:ok, current}

  defp required(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp state do
    scenario = Server.scenario()
    clock = Server.clock()

    %{
      "now" => Payloads.iso(Server.now()),
      "speed" => clock.speed,
      "channels" => Enum.map(scenario.channels, &channel_state/1),
      "faults" => scenario.faults,
      "webhooks" => webhooks(),
      "pusher" => %{"app_key" => Server.pusher().app_key, "sockets" => Hub.count()}
    }
  end

  defp channel_state(channel) do
    now = Server.now()
    window = Schedule.stream_at(channel, now)
    live = window && Payloads.livestream(channel, now)

    %{
      "slug" => channel.slug,
      "user_id" => channel.user_id,
      "chatroom_id" => channel.chatroom_id,
      "live" => window != nil,
      "started_at" => window && Payloads.iso(window.started_at),
      "ends_at" => window && Payloads.iso(window.ends_at),
      "viewers" => (live && live["viewer_count"]) || 0,
      "title" => live && live["stream_title"],
      "category" => live && live["category"]["name"],
      "followers" => Sim.Curve.followers(channel, now),
      "next_start" => if(window, do: nil, else: iso_or_nil(Schedule.next_start(channel, now)))
    }
  end

  defp webhooks do
    sent = Webhooks.sent()

    %{
      "url" => Webhooks.webhook_url(),
      "subscriptions" => length(Webhooks.list()),
      "sent" => Enum.count(sent, &(not Map.get(&1, :dropped, false))),
      "dropped" => Enum.count(sent, &Map.get(&1, :dropped, false)),
      "drop_next" => Webhooks.dropping(),
      "recent" =>
        sent
        |> Enum.take(20)
        |> Enum.map(
          &%{
            "event" => &1.event,
            "at" => Payloads.iso(&1.at),
            "dropped" => Map.get(&1, :dropped, false)
          }
        )
    }
  end

  defp iso_or_nil(nil), do: nil
  defp iso_or_nil(at), do: Payloads.iso(at)

  @statuses %{
    unknown_channel: 404,
    not_live: 409,
    already_live: 409
  }

  defp error(conn, reason) do
    key = if is_tuple(reason), do: elem(reason, 0), else: reason
    json(conn, Map.get(@statuses, key, 400), %{"error" => describe(reason)})
  end

  defp describe({key, detail}), do: "#{key}: #{detail}"
  defp describe(key), do: to_string(key)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
