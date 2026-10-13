defmodule Sim.Http.Router do
  @moduledoc """
  The fake Kick's HTTP side. One port serves what the real Kick spreads over
  several hosts, so a client points `KICK_ID_URL`, `KICK_API_URL`,
  `KICK_V2_URL` and `KICK_REALTIME_URL` at the same base:

    * `POST /oauth/token` — app access tokens (id.kick.com)
    * `GET /public/v1/public-key`, `/channels`, `/livestreams`,
      and `/events/subscriptions` (api.kick.com)
    * `GET /api/v2/channels/:slug` — the private endpoint (kick.com)
    * `POST /api/v1/realtime/connection`,
      `/api/v1/realtime/channels/:id/chat/connection` and
      `/api/v1/realtime/auth/connection` — where the chat is served and a
      guest token for it (web.kick.com)
    * `GET /connection/websocket` — the chat's Centrifugo websocket
      (realtime.<region>.platform.kick.com)

  It copies the behaviour the recordings showed, not just the happy path: a
  missing token is 401, an unknown slug fails the whole request with 400,
  and at most 50 channels are accepted per request.
  """

  use Plug.Router

  alias Sim.{Payloads, Scenario, Server, Webhooks}

  @max_per_request 50

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  # The simulator's own controls, not part of Kick (see `Sim.Http.Control`).
  forward("/_sim", to: Sim.Http.Control)

  post "/oauth/token" do
    case conn.body_params do
      %{"grant_type" => "client_credentials", "client_id" => id, "client_secret" => secret}
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" ->
        json(conn, 200, Payloads.token(Server.issue_token()))

      _ ->
        json(conn, 400, %{"error" => "Invalid request"})
    end
  end

  get "/public/v1/public-key" do
    json(conn, 200, Payloads.public_key(Server.public_key_pem()))
  end

  get "/public/v1/channels" do
    with_token(conn, fn ->
      params = query(conn)
      slugs = Map.get(params, "slug", [])
      ids = params |> Map.get("broadcaster_user_id", []) |> Enum.map(&to_integer/1)

      cond do
        slugs != [] and ids != [] ->
          json(conn, 400, Payloads.error("Invalid request"))

        length(slugs) > @max_per_request or length(ids) > @max_per_request ->
          json(conn, 400, Payloads.error("Invalid request"))

        true ->
          channels(conn, slugs, ids)
      end
    end)
  end

  get "/public/v1/livestreams" do
    with_token(conn, fn ->
      params = query(conn)
      scenario = Server.scenario()
      at = Server.now()

      ids = params |> Map.get("broadcaster_user_id", []) |> Enum.map(&to_integer/1)
      limit = params |> Map.get("limit", []) |> List.first() |> to_limit()

      wanted =
        if ids == [],
          do: scenario.channels,
          else: Enum.filter(scenario.channels, &(&1.user_id in ids))

      live =
        wanted
        |> Enum.map(&Payloads.livestream(&1, at))
        |> Enum.reject(&is_nil/1)
        |> sort(params |> Map.get("sort", []) |> List.first())
        |> Enum.take(limit)

      json(conn, 200, Payloads.ok(live))
    end)
  end

  post "/public/v1/events/subscriptions" do
    with_token(conn, fn ->
      case conn.body_params do
        %{"broadcaster_user_id" => user_id, "events" => events} when is_list(events) ->
          json(conn, 200, Payloads.ok(Webhooks.subscribe(user_id, events)))

        _ ->
          json(conn, 400, Payloads.error("Invalid request"))
      end
    end)
  end

  get "/public/v1/events/subscriptions" do
    with_token(conn, fn -> json(conn, 200, Payloads.ok(Webhooks.list())) end)
  end

  delete "/public/v1/events/subscriptions" do
    with_token(conn, fn ->
      Webhooks.unsubscribe(Map.get(query(conn), "id", []))
      send_resp(conn, 204, "")
    end)
  end

  # Kick's realtime chat, on the same port: where to connect (the general
  # answer and a channel's are the same here, one region), a guest token,
  # then the websocket.
  post "/api/v1/realtime/connection" do
    realtime_connection(conn)
  end

  post "/api/v1/realtime/channels/:id/chat/connection" do
    realtime_connection(conn)
  end

  post "/api/v1/realtime/auth/connection" do
    case conn.body_params do
      %{"client_id" => id} when is_binary(id) and id != "" ->
        json(conn, 200, %{
          "data" => %{"token" => Server.issue_realtime_token()},
          "message" => "success"
        })

      _ ->
        json(conn, 400, Payloads.error("Invalid request"))
    end
  end

  # Kick's server refuses a handshake from anywhere but kick.com.
  get "/connection/websocket" do
    if get_req_header(conn, "origin") == ["https://kick.com"] do
      conn
      |> WebSockAdapter.upgrade(Sim.Realtime.Socket, %{}, timeout: 3_600_000)
      |> halt()
    else
      conn |> send_resp(403, "") |> halt()
    end
  end

  # Channels' pictures and thumbnails: a solid colour per name.
  get "/assets/:kind/:file" do
    conn
    |> put_resp_content_type("image/png", nil)
    |> send_resp(200, Sim.Png.solid(64, Sim.Png.colour(kind <> "/" <> file)))
  end

  # Emotes, as Kick's file host serves them (`KICK_FILES_URL`): a solid
  # colour per emote id.
  get "/emotes/:id/fullsize" do
    conn
    |> put_resp_content_type("image/png", nil)
    |> send_resp(200, Sim.Png.solid(32, Sim.Png.colour("emote/" <> id)))
  end

  get "/api/v2/channels/:slug" do
    case Scenario.channel(Server.scenario(), slug) do
      nil -> json(conn, 404, %{"message" => "Not Found"})
      channel -> json(conn, 200, Payloads.v2_channel(channel, Server.now()))
    end
  end

  match _ do
    json(conn, 404, %{"message" => "Not Found"})
  end

  defp channels(conn, slugs, ids) do
    scenario = Server.scenario()
    at = Server.now()

    found =
      case {slugs, ids} do
        {[], []} -> {:ok, []}
        {[], ids} -> collect(ids, &Scenario.channel_by_user_id(scenario, &1))
        {slugs, _} -> collect(slugs, &Scenario.channel(scenario, &1))
      end

    case found do
      # One unknown channel fails the whole request, as the real API does.
      :error ->
        json(conn, 400, Payloads.error("Invalid request"))

      {:ok, channels} ->
        json(conn, 200, Payloads.ok(Enum.map(channels, &Payloads.channel(&1, at))))
    end
  end

  defp realtime_connection(conn) do
    url = "ws://#{conn.host}:#{conn.port}/connection/websocket"

    json(conn, 200, %{
      "data" => %{
        "connections" => [%{"provider" => "centrifugo", "credentials" => %{"url" => url}}],
        "mode" => "websocket"
      },
      "message" => "success"
    })
  end

  defp collect(keys, lookup) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case lookup.(key) do
        nil -> {:halt, :error}
        channel -> {:cont, {:ok, acc ++ [channel]}}
      end
    end)
  end

  defp with_token(conn, fun) do
    token =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> case do
        "Bearer " <> token -> token
        _ -> nil
      end

    if Server.valid_token?(token),
      do: fun.(),
      else: json(conn, 401, Payloads.error("Unauthorized"))
  end

  defp sort(livestreams, "viewer_count"),
    do: Enum.sort_by(livestreams, & &1["viewer_count"], :desc)

  defp sort(livestreams, "started_at"), do: Enum.sort_by(livestreams, & &1["started_at"])
  defp sort(livestreams, _), do: livestreams

  # Kick repeats query keys (`?slug=a&slug=b`), which Plug's params collapse.
  defp query(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, String.trim_trailing(key, "[]"), [value], &(&1 ++ [value]))
    end)
  end

  defp to_integer(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end

  defp to_limit(nil), do: 25

  defp to_limit(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 100)
      _ -> 25
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
