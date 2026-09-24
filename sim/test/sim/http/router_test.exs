defmodule Sim.Http.RouterTest do
  use ExUnit.Case, async: false

  alias Sim.{Clock, Scenario, Server}

  # A Monday evening: the evening channel is live, the weekend one is not.
  @now ~U[2026-01-05 21:00:00Z]

  setup do
    scenario =
      Scenario.new(
        channels: [
          [
            slug: "bigstreamer",
            peak_viewers: 5_000,
            schedule: %{days: [1, 3], start_hour: 20, duration_min: 180}
          ],
          [
            slug: "weekender",
            peak_viewers: 50,
            schedule: %{days: [6, 7], start_hour: 14, duration_min: 120}
          ]
        ]
      )

    start_supervised!(
      {Sim.Instance,
       scenario: scenario, clock: Clock.new(sim_start: @now), port: 0, webhook_url: nil}
    )

    %{base: Sim.Instance.base_url(), scenario: scenario}
  end

  defp get(base, path, opts \\ []) do
    Req.get!(
      url: base <> path,
      params: Keyword.get(opts, :params, []),
      headers: token_header(opts[:token]),
      retry: false,
      decode_body: false
    )
  end

  defp token_header(nil), do: []
  defp token_header(token), do: [{"authorization", "Bearer " <> token}]

  defp body(response), do: Jason.decode!(response.body)

  defp token(base) do
    response =
      Req.post!(
        url: base <> "/oauth/token",
        form: [grant_type: "client_credentials", client_id: "id", client_secret: "secret"],
        retry: false,
        decode_body: false
      )

    body(response)["access_token"]
  end

  describe "tokens" do
    test "client credentials get a token that the API then accepts", %{base: base} do
      response =
        Req.post!(
          url: base <> "/oauth/token",
          form: [grant_type: "client_credentials", client_id: "id", client_secret: "secret"],
          retry: false,
          decode_body: false
        )

      assert response.status == 200

      assert %{"access_token" => token, "token_type" => "Bearer", "expires_in" => 5_184_000} =
               body(response)

      assert get(base, "/public/v1/livestreams", token: token).status == 200
    end

    test "a request without credentials is refused", %{base: base} do
      response =
        Req.post!(
          url: base <> "/oauth/token",
          form: [grant_type: "client_credentials"],
          retry: false,
          decode_body: false
        )

      assert response.status == 400
    end

    test "no token, or one we never issued, is 401 in Kick's shape", %{base: base} do
      response = get(base, "/public/v1/livestreams")

      assert response.status == 401
      assert body(response) == %{"data" => %{}, "message" => "Unauthorized"}
      assert get(base, "/public/v1/channels", token: "made-up").status == 401
    end
  end

  describe "GET /public/v1/livestreams" do
    test "returns only the channels that are live right now", %{base: base} do
      response = get(base, "/public/v1/livestreams", token: token(base))

      assert response.status == 200
      assert [stream] = body(response)["data"]
      assert stream["slug"] == "bigstreamer"
      assert stream["started_at"] == "2026-01-05T20:00:00Z"
      assert stream["viewer_count"] > 0
    end

    test "filters by broadcaster id, repeated the way Kick expects", %{
      base: base,
      scenario: scenario
    } do
      big = Scenario.channel(scenario, "bigstreamer")
      weekender = Scenario.channel(scenario, "weekender")
      t = token(base)

      both =
        get(base, "/public/v1/livestreams",
          token: t,
          params: [broadcaster_user_id: big.user_id, broadcaster_user_id: weekender.user_id]
        )

      assert length(body(both)["data"]) == 1

      none =
        get(base, "/public/v1/livestreams",
          token: t,
          params: [broadcaster_user_id: weekender.user_id]
        )

      assert body(none)["data"] == []
      assert body(none)["message"] == "OK"
    end

    test "respects limit and sorting", %{base: base} do
      t = token(base)

      assert body(get(base, "/public/v1/livestreams", token: t, params: [limit: 0]))["data"] != []

      assert length(
               body(get(base, "/public/v1/livestreams", token: t, params: [sort: "viewer_count"]))[
                 "data"
               ]
             ) == 1
    end
  end

  describe "GET /public/v1/channels" do
    test "returns live and offline channels alike, in the order asked for", %{base: base} do
      response =
        get(base, "/public/v1/channels",
          token: token(base),
          params: [slug: "weekender", slug: "bigstreamer"]
        )

      assert response.status == 200
      assert [weekender, big] = body(response)["data"]
      assert weekender["slug"] == "weekender"
      assert weekender["stream"]["is_live"] == false
      assert weekender["stream"]["start_time"] == "0001-01-01T00:00:00Z"
      assert big["stream"]["is_live"] == true
      assert big["stream"]["viewer_count"] > 0
    end

    test "one unknown slug fails the whole request, as the real API does", %{base: base} do
      response =
        get(base, "/public/v1/channels",
          token: token(base),
          params: [slug: "bigstreamer", slug: "nobody"]
        )

      assert response.status == 400
      assert body(response) == %{"data" => %{}, "message" => "Invalid request"}
    end

    test "slug and broadcaster id can't be mixed, and 50 is the limit", %{base: base} do
      t = token(base)

      assert get(base, "/public/v1/channels",
               token: t,
               params: [slug: "bigstreamer", broadcaster_user_id: 1]
             ).status == 400

      many = for n <- 1..51, do: {:slug, "channel#{n}"}
      assert get(base, "/public/v1/channels", token: t, params: many).status == 400
    end

    test "looks channels up by broadcaster id too", %{base: base, scenario: scenario} do
      big = Scenario.channel(scenario, "bigstreamer")

      response =
        get(base, "/public/v1/channels",
          token: token(base),
          params: [broadcaster_user_id: big.user_id]
        )

      assert [%{"slug" => "bigstreamer"}] = body(response)["data"]
    end
  end

  describe "the other endpoints" do
    test "the public key is a PEM the signature code can use", %{base: base} do
      response = get(base, "/public/v1/public-key")
      pem = body(response)["data"]["public_key"]

      assert response.status == 200
      assert pem =~ "BEGIN PUBLIC KEY"
      assert {:ok, _key} = Sim.Kick.Signature.decode_public_key(pem)
      assert pem == Server.public_key_pem()
    end

    test "v2 serves the follower total without a token, and 404s for an unknown channel", %{
      base: base
    } do
      response = get(base, "/api/v2/channels/bigstreamer")

      assert response.status == 200
      assert body(response)["followers_count"] > 0
      assert body(response)["chatroom"]["id"] > 0
      assert get(base, "/api/v2/channels/nobody").status == 404
    end

    test "anything else is a 404, not a crash", %{base: base} do
      assert get(base, "/nope").status == 404
      assert get(base, "/public/v1/nope", token: token(base)).status == 404
    end
  end

  describe "webhook subscriptions" do
    test "subscribe, list and delete round-trip in Kick's shapes", %{
      base: base,
      scenario: scenario
    } do
      t = token(base)
      big = Scenario.channel(scenario, "bigstreamer")

      created =
        Req.post!(
          url: base <> "/public/v1/events/subscriptions",
          headers: token_header(t),
          json: %{
            "broadcaster_user_id" => big.user_id,
            "events" => [%{"name" => "livestream.status.updated", "version" => 1}],
            "method" => "webhook"
          },
          retry: false,
          decode_body: false
        )

      assert created.status == 200

      assert [%{"name" => "livestream.status.updated", "version" => 1, "subscription_id" => id}] =
               body(created)["data"]

      listed = body(get(base, "/public/v1/events/subscriptions", token: t))["data"]

      assert [%{"id" => ^id, "event" => "livestream.status.updated", "method" => "webhook"}] =
               listed

      deleted =
        Req.request!(
          method: :delete,
          url: base <> "/public/v1/events/subscriptions",
          params: [id: id],
          headers: token_header(t),
          retry: false,
          decode_body: false
        )

      assert deleted.status == 204
      assert body(get(base, "/public/v1/events/subscriptions", token: t))["data"] == []
    end
  end

  describe "time moves" do
    test "the same channel's viewers hold for a minute and change after it", %{base: base} do
      t = token(base)

      viewers = fn ->
        body(get(base, "/public/v1/livestreams", token: t))["data"]
        |> hd()
        |> Map.get("viewer_count")
      end

      first = viewers.()
      Server.put_clock(Clock.new(sim_start: DateTime.add(@now, 30, :second)))
      assert viewers.() == first

      Server.put_clock(Clock.new(sim_start: DateTime.add(@now, 90, :second)))
      assert viewers.() != first
    end

    test "a channel goes offline when its window ends", %{base: base} do
      t = token(base)
      assert body(get(base, "/public/v1/livestreams", token: t))["data"] != []

      Server.put_clock(Clock.new(sim_start: ~U[2026-01-05 23:30:00Z]))
      assert body(get(base, "/public/v1/livestreams", token: t))["data"] == []

      assert body(get(base, "/public/v1/channels", token: t, params: [slug: "bigstreamer"]))[
               "data"
             ]
             |> hd()
             |> get_in(["stream", "is_live"]) == false
    end
  end
end
