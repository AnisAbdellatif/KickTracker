defmodule Sim.Recorder.ProbeTest do
  use ExUnit.Case, async: true

  alias Sim.Recorder.Probe

  @ids %{slug: "somestreamer", user_id: 1_234_567, channel_id: 7_654_321, livestream_id: 555}
  @bases %{api: "https://api.kick.com", site: "https://kick.com"}

  test "builds every candidate when all ids are known, on the right hosts" do
    candidates = Probe.candidates(@ids, @bases)
    by_name = Map.new(candidates, &{&1.name, &1})

    assert by_name["followers-count-by-channel-id"].url ==
             "https://api.kick.com/channels/7654321/followers-count"

    assert by_name["followers-count-by-user-id"].url ==
             "https://api.kick.com/channels/1234567/followers-count"

    assert by_name["v2-leaderboards"].url ==
             "https://kick.com/api/v2/channels/somestreamer/leaderboards"

    assert by_name["current-viewers"].params == ["ids[]": 555]

    # Only api.kick.com endpoints are retried with our app token.
    assert Enum.all?(candidates, fn c ->
             c.token_retry == String.starts_with?(c.url, "https://api.kick.com")
           end)

    assert Enum.all?(candidates, &is_binary(&1.why))
  end

  test "skips endpoints whose id couldn't be resolved" do
    names =
      %{@ids | channel_id: nil, livestream_id: nil}
      |> Probe.candidates(@bases)
      |> Enum.map(& &1.name)

    refute "followers-count-by-channel-id" in names
    refute "viewer-count-by-channel-id" in names
    refute "current-viewers" in names
    assert "followers-count-by-user-id" in names
    assert "v2-leaderboards" in names
  end

  test "slugs are URL-encoded" do
    [candidate | _] =
      %{@ids | slug: "some streamer"}
      |> Probe.candidates(@bases)
      |> Enum.filter(&(&1.name == "v2-clips"))

    assert candidate.url == "https://kick.com/api/v2/channels/some%20streamer/clips"
  end

  test "hosts come from configuration" do
    bases = %{api: "http://127.0.0.1:4001", site: "http://127.0.0.1:4002"}
    urls = @ids |> Probe.candidates(bases) |> Enum.map(& &1.url)

    assert Enum.all?(urls, &String.starts_with?(&1, "http://127.0.0.1:400"))
    assert Probe.site_base("https://kick.com/api/v2") == "https://kick.com"
    assert Probe.site_base("http://127.0.0.1:4002/api/v2/") == "http://127.0.0.1:4002"
  end

  test "retries with the token only for api.kick.com on 401/403" do
    [private | _] = Probe.candidates(@ids, @bases)
    site = Enum.find(Probe.candidates(@ids, @bases), &(not &1.token_retry))

    assert Probe.retry_with_token?(private, 401)
    assert Probe.retry_with_token?(private, 403)
    refute Probe.retry_with_token?(private, 404)
    refute Probe.retry_with_token?(site, 401)
  end

  defp rec(status, body, content_type \\ "application/json") do
    %{
      "response" => %{
        "status" => status,
        "headers" => [["Content-Type", content_type]],
        "body" => body
      }
    }
  end

  test "describes JSON by shape and count-like field paths, never values" do
    body =
      Jason.encode!(%{
        "followers_count" => 25_000,
        "user" => %{"username" => "somestreamer"},
        "livestream" => %{"viewer_count" => 612, "title" => "secret title"},
        "data" => [%{"subscriber_count" => 3}]
      })

    d = Probe.describe(rec(200, body))

    assert d["status"] == 200
    assert d["json"] == true
    assert d["top_level"] == ["data", "followers_count", "livestream", "user"]

    assert d["count_fields"] == [
             "data.[].subscriber_count",
             "followers_count",
             "livestream.viewer_count"
           ]

    refute inspect(d) =~ ~r/25000|612|somestreamer|secret/
  end

  test "recognizes a Cloudflare challenge page" do
    d = Probe.describe(rec(403, "<html><title>Just a moment...</title></html>", "text/html"))
    assert %{"json" => false, "looks_like" => "cloudflare challenge", "status" => 403} = d
  end

  test "a bare number or list is described by type" do
    assert Probe.describe(rec(200, "25000"))["top_level"] == "number"
    assert Probe.describe(rec(200, "[1,2,3]"))["top_level"] == "list of 3"
  end
end
