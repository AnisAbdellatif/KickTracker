defmodule KickTracker.AvatarsTest do
  @moduledoc "Channels' pictures (§12.9): recognised, learnt, copied, served from our domain."

  use KickTracker.SimCase
  @moduletag :capture_log
  use Oban.Testing, repo: KickTracker.Repo

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  alias KickTracker.{Avatars, Channels}
  alias KickTracker.Tracking.Manager
  alias KickTracker.Workers.ChannelAvatar

  @endpoint KickTrackerWeb.Endpoint

  describe "recognising an image" do
    test "by its first bytes: PNG, JPEG, GIF, WebP; nothing else, SVG included" do
      assert Avatars.sniff(Sim.Png.solid(2, {1, 2, 3})) == "image/png"
      assert Avatars.sniff(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>) == "image/jpeg"
      assert Avatars.sniff("GIF89a....") == "image/gif"
      assert Avatars.sniff("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ") == "image/webp"
      assert Avatars.sniff(~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)) == nil
      assert Avatars.sniff("<html>") == nil
      assert Avatars.sniff("") == nil
    end

    test "only http(s) URLs with a host are fetched" do
      assert Avatars.fetchable?("https://files.example/a.webp")
      assert Avatars.fetchable?("http://127.0.0.1:4050/assets/profile/x.png")
      refute Avatars.fetchable?("file:///etc/passwd")
      refute Avatars.fetchable?("javascript:alert(1)")
      refute Avatars.fetchable?("")
      refute Avatars.fetchable?(nil)
    end
  end

  describe "from Kick to the page" do
    setup do
      start_sim([
        [slug: "livestreamer", schedule: :always],
        [slug: "offlinestreamer", schedule: :never]
      ])

      start_collector()
      {:ok, c} = Channels.add("livestreamer")
      Manager.sync()
      %{channel: c}
    end

    test "a poll learns the picture, a job copies it, the site serves it and pages show it",
         %{channel: c} do
      poll()
      settle()

      url = KickTracker.Repo.reload(c).avatar_url
      assert url =~ "/assets/profile/livestreamer.png"
      assert_enqueued(worker: ChannelAvatar, args: %{"channel_id" => c.id})

      assert perform_job(ChannelAvatar, %{"channel_id" => c.id}) == :ok
      assert Avatars.refresh(c.id) == :unchanged
      [version] = Map.values(Avatars.versions())

      conn = get(build_conn(), "/img/channels/#{c.id}/avatar?v=#{version}")
      assert response(conn, 200) == Sim.Png.solid(64, Sim.Png.colour("profile/livestreamer.png"))
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      [etag] = get_resp_header(conn, "etag")

      assert build_conn()
             |> put_req_header("if-none-match", etag)
             |> get("/img/channels/#{c.id}/avatar")
             |> response(304)

      # The same picture again learns nothing and queues nothing.
      Oban.drain_queue(queue: :kick)
      poll()
      settle()
      refute_enqueued(worker: ChannelAvatar, args: %{"channel_id" => c.id})

      {:ok, _view, html} = live(build_conn(), "/c/livestreamer")
      assert html =~ "/img/channels/#{c.id}/avatar?v=#{version}"
    end

    test "a hidden channel's picture isn't served, and pages keep its initial", %{channel: c} do
      poll()
      settle()
      :ok = perform_job(ChannelAvatar, %{"channel_id" => c.id})
      {:ok, _} = Channels.set_public(c, false)

      assert build_conn() |> get("/img/channels/#{c.id}/avatar") |> response(404)
      assert Avatars.versions() == %{}
    end

    test "deleting a channel deletes its picture", %{channel: c} do
      poll()
      settle()
      :ok = perform_job(ChannelAvatar, %{"channel_id" => c.id})
      assert :ok = perform_job(KickTracker.Workers.DeleteChannel, %{"channel_id" => c.id})
      assert rows("channel_avatars", ["channel_id"]) == []
    end

    test "something that isn't an image is not kept; the initial stays", %{channel: c} do
      Repo.query!("UPDATE channels SET avatar_url = $1 WHERE id = $2", [
        Sim.Instance.base_url() <> "/public/v1/public-key",
        c.id
      ])

      assert Avatars.refresh(c.id) == {:error, :not_an_image}
      assert rows("channel_avatars", ["channel_id"]) == []
      assert build_conn() |> get("/img/channels/#{c.id}/avatar") |> response(404)
    end

    test "the daily sweep queues channels whose picture isn't copied", %{channel: c} do
      Repo.query!("UPDATE channels SET avatar_url = 'http://x.example/a.png' WHERE id = $1", [
        c.id
      ])

      assert Avatars.stale() == [c.id]
      :ok = perform_job(ChannelAvatar, %{"sweep" => true})
      assert_enqueued(worker: ChannelAvatar, args: %{"channel_id" => c.id})
    end
  end
end
