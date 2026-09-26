defmodule KickTrackerWeb.Admin.AnomaliesLiveTest do
  use KickTrackerWeb.ConnCase

  import Phoenix.LiveViewTest
  alias KickTracker.{Anomalies, Fixtures, Repo}

  @day0 ~U[2026-03-01 20:00:00Z]

  # A two-hour stream on day `d`: an audience that builds and wobbles, and
  # chat at 5% of it. With `jump: true`, 1 500 viewers arrive at minute 60
  # and chat doesn't change.
  defp stream!(channel, d, opts \\ []) do
    start = DateTime.add(@day0, d, :day)
    at = fn i -> DateTime.add(start, i * 60 + 30) end
    id = Fixtures.stream!(channel, start, at.(120))

    base =
      for i <- 0..119 do
        share = min(1.0, 0.2 + i / 15 * 0.8)
        round(1000 * share + 15 * :math.sin(i * 1.3) + 10 * :math.cos(i * 0.7))
      end

    viewers =
      if opts[:jump],
        do:
          base
          |> Enum.with_index()
          |> Enum.map(fn {v, i} -> if i >= 60, do: v + 1500, else: v end),
        else: base

    Fixtures.samples!(
      channel,
      id,
      viewers |> Enum.with_index() |> Enum.map(fn {v, i} -> {at.(i), v} end)
    )

    Repo.insert_all(
      "chat_minutes",
      for {v, i} <- Enum.with_index(base) do
        minute = DateTime.add(start, i * 60)

        %{
          channel_id: channel.id,
          minute: minute,
          stream_id: id,
          messages: v,
          chatters: round(v * 0.05)
        }
      end
    )

    Fixtures.covered!(channel, "chat", start, at.(120))
    {id, at}
  end

  setup :log_in_admin

  setup do
    channel = Fixtures.channel!(slug: "somestreamer")
    for d <- 0..4, do: stream!(channel, d)
    {target, at} = stream!(channel, 5, jump: true)
    %{channel: channel, target: target, at: at}
  end

  test "lists a channel's streams with what was found, and shows one stream's findings", %{
    conn: conn,
    channel: channel,
    target: target
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/anomalies?channel=#{channel.id}")

    assert view |> element("#stream-#{target}") |> render() =~ "Jump without chat"
    # The earlier, ordinary streams show nothing.
    assert view
           |> element("#anomaly-streams")
           |> render()
           |> String.split("Jump without chat")
           |> length() == 2

    {:ok, view, html} = live(conn, ~p"/admin/anomalies/#{target}")
    assert html =~ "Viewers went from"
    assert has_element?(view, "#anomaly-chart")
    # Its figures against the five earlier streams'.
    assert html =~ "median of 5 earlier streams"
  end

  test "the chart's data carries the findings as shaded stretches", %{conn: conn, target: target} do
    data =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/admin/anomalies/#{target}/chart")
      |> json_response(200)

    assert [%{"text" => "Jump without chat"}] = data["annotations"]
    assert length(data["viewers"]["t"]) >= 120
  end

  test "an incoming host at the jump explains it", %{channel: channel, target: target, at: at} do
    assert [%{kind: :unexplained_jump}] = findings(channel, target)

    Repo.insert_all("channel_events", [
      %{
        channel_id: channel.id,
        occurred_at: at.(60),
        kind: "hosted_by",
        dedup_key: "somehost",
        payload: %{}
      }
    ])

    assert findings(channel, target) == []
  end

  test "a stream without chat coverage is not judged against chat", %{channel: channel} do
    {id, at} = stream!(channel, 6, jump: true)

    Repo.query!("DELETE FROM coverage WHERE channel_id = $1 AND from_at >= $2", [
      channel.id,
      at.(-1)
    ])

    assert findings(channel, id) == []
    assert Anomalies.stream(channel, id).profile.engagement == nil
  end

  test "only admins see it", %{target: target} do
    conn = build_conn()
    assert redirected_to(get(conn, ~p"/admin/anomalies")) == "/admin/login"
    assert redirected_to(get(conn, ~p"/admin/anomalies/#{target}")) == "/admin/login"

    assert conn
           |> put_req_header("accept", "application/json")
           |> get(~p"/admin/anomalies/#{target}/chart")
           |> json_response(401)
  end

  defp findings(channel, id), do: Anomalies.stream(channel, id).findings
end
