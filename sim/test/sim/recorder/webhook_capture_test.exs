defmodule Sim.Recorder.WebhookCaptureTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Sim.Kick.Signature
  alias Sim.Recorder.{WebhookCapture, WebhookPolicy}

  @body ~s({"broadcaster": {"user_id": 7},  "is_live": true}\n)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    {private, pem} = Sim.TestKeys.pair()
    %{private: private, pem: pem}
  end

  defp deliver(opts, headers, body \\ @body) do
    conn = conn(:post, "/", body)
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    WebhookCapture.call(conn, WebhookCapture.init(opts))
  end

  defp kick_headers(private, id, ts \\ "2026-09-24T18:02:11Z", body \\ @body) do
    [
      {"kick-event-message-id", id},
      {"kick-event-message-timestamp", ts},
      {"kick-event-type", "livestream.status.updated"},
      {"kick-event-version", "1"},
      {"kick-event-signature", Signature.sign(private, id, ts, body)}
    ]
  end

  defp recordings(dir) do
    dir
    |> Path.join("webhook/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  @tag :tmp_dir
  test "records headers and the raw body byte for byte, with a valid signature",
       %{tmp_dir: dir} = ctx do
    {:ok, policy} = WebhookPolicy.start_link([])

    conn =
      deliver([run: dir, policy: policy, public_key: ctx.pem], kick_headers(ctx.private, "m1"))

    assert conn.status == 200
    assert [rec] = recordings(dir)
    assert rec["request"]["body"] == @body
    assert rec["signature_valid"] == true
    assert rec["answered"] == 200
    assert ["kick-event-message-id", "m1"] in rec["request"]["headers"]
  end

  @tag :tmp_dir
  test "a tampered delivery is still recorded, flagged invalid", %{tmp_dir: dir} = ctx do
    {:ok, policy} = WebhookPolicy.start_link([])

    deliver(
      [run: dir, policy: policy, public_key: ctx.pem],
      kick_headers(ctx.private, "m1"),
      @body <> " "
    )

    assert [%{"signature_valid" => false}] = recordings(dir)
  end

  @tag :tmp_dir
  test "without a public key the signature is not judged", %{tmp_dir: dir} = ctx do
    {:ok, policy} = WebhookPolicy.start_link([])
    deliver([run: dir, policy: policy, public_key: nil], kick_headers(ctx.private, "m1"))

    assert [%{"signature_valid" => nil}] = recordings(dir)
  end

  @tag :tmp_dir
  test "answers per the policy, so retries can be provoked", %{tmp_dir: dir} = ctx do
    {:ok, policy} = WebhookPolicy.start_link(fail_first: 2)
    opts = [run: dir, policy: policy, public_key: ctx.pem]

    statuses = for _ <- 1..3, do: deliver(opts, kick_headers(ctx.private, "m1")).status
    assert statuses == [500, 500, 200]
  end

  @tag :tmp_dir
  test "anything but POST is 404 and records nothing", %{tmp_dir: dir} do
    {:ok, policy} = WebhookPolicy.start_link([])
    conn = WebhookCapture.call(conn(:get, "/"), run: dir, policy: policy)

    assert conn.status == 404
    assert recordings(dir) == []
  end
end
