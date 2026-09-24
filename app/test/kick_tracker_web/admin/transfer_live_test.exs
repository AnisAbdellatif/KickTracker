defmodule KickTrackerWeb.Admin.TransferLiveTest do
  @moduledoc """
  The export / import page: an export is queued, run by the worker and
  downloaded; an upload is previewed, confirmed and merged.
  """

  use KickTrackerWeb.ConnCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures
  alias KickTracker.{Audit, Transfers}
  alias KickTracker.Workers.Transfer, as: Worker

  setup :log_in_admin

  test "an export is queued, built by the collector and downloaded", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    s = stream!(c, ~U[2026-09-01 20:00:00Z], ~U[2026-09-01 21:00:00Z])
    samples!(c, s, [{~U[2026-09-01 20:00:00Z], 10}, {~U[2026-09-01 20:01:00Z], 12}])

    {:ok, view, _} = live(conn, ~p"/admin/transfer")

    view
    |> form("#export-form",
      export: %{scope: "data", channel_ids: ["#{c.id}"], from: "2026-09-01", to: "2026-09-01"}
    )
    |> render_submit()

    [t] = Transfers.list()
    assert %{kind: "export", status: "queued", options: %{"from" => "2026-09-01T00:00:00Z"}} = t
    assert_enqueued(worker: Worker, args: %{"transfer_id" => t.id})
    assert [%{action: "transfer.export"} | _] = Audit.recent()

    assert :ok = perform_job(Worker, %{"transfer_id" => t.id})

    assert %{status: "done", manifest: %{"rows" => %{"viewer_samples" => 2}}} =
             Transfers.get!(t.id)

    send(view.pid, :refresh)
    assert render(view) =~ "Download"

    conn = get(conn, ~p"/admin/transfers/#{t.id}/download")
    assert conn.status == 200
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/export-\d{8}-\d{4}\.zip/

    {:ok, files} = :zip.extract(conn.resp_body, [:memory])
    names = Enum.map(files, fn {name, _} -> List.to_string(name) end)
    assert "manifest.json" in names and "viewer_samples.csv" in names
  end

  test "an export needs a channel", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/transfer")
    html = view |> form("#export-form", export: %{scope: "data"}) |> render_submit()
    assert html =~ "Pick at least one channel"
    assert Transfers.list() == []
  end

  test "an upload is previewed, then merged once confirmed", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    {:ok, t} = Transfers.request_export(nil, %{"scope" => "channels", "channel_ids" => [c.id]})
    :ok = perform_job(Worker, %{"transfer_id" => t.id})
    zip = File.read!(Transfers.path(Transfers.get!(t.id)))
    KickTracker.Repo.query!("DELETE FROM channels")

    {:ok, view, _} = live(conn, ~p"/admin/transfer")

    upload =
      file_input(view, "#upload-form", :archive, [
        %{name: "export.zip", content: zip, type: "application/zip"}
      ])

    render_upload(upload, "export.zip")
    html = view |> form("#upload-form") |> render_submit()
    assert html =~ "import-preview"
    assert html =~ "somestreamer"
    assert [%{action: "transfer.upload"} | _] = Audit.recent()

    view |> element("#confirm-import") |> render_click()
    [import | _] = Transfers.list()
    assert %{kind: "import", status: "queued"} = import

    assert :ok = perform_job(Worker, %{"transfer_id" => import.id})
    assert %{status: "done", summary: %{"new_channels" => [_]}} = Transfers.get!(import.id)
    assert KickTracker.Channels.get_by_slug("somestreamer")
  end

  test "a file that isn't an export is refused", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/transfer")

    upload =
      file_input(view, "#upload-form", :archive, [
        %{name: "junk.zip", content: "not a zip", type: "application/zip"}
      ])

    render_upload(upload, "junk.zip")
    html = view |> form("#upload-form") |> render_submit()
    assert html =~ "Can&#39;t import this file"
    assert [%{status: "failed"}] = Transfers.list()
    assert [%{action: "transfer.upload", details: %{"error" => _}} | _] = Audit.recent()
  end

  test "an upload discarded before confirming is audited", %{conn: conn} do
    c = channel!(slug: "somestreamer")
    {:ok, t} = Transfers.request_export(nil, %{"scope" => "channels", "channel_ids" => [c.id]})
    :ok = perform_job(Worker, %{"transfer_id" => t.id})
    zip = File.read!(Transfers.path(Transfers.get!(t.id)))

    {:ok, view, _} = live(conn, ~p"/admin/transfer")

    upload =
      file_input(view, "#upload-form", :archive, [
        %{name: "export.zip", content: zip, type: "application/zip"}
      ])

    render_upload(upload, "export.zip")
    view |> form("#upload-form") |> render_submit()
    view |> element("button[phx-click=discard]") |> render_click()
    assert [%{action: "transfer.discard"} | _] = Audit.recent()
  end

  test "old files are pruned" do
    {:ok, t} = Transfers.request_export(nil, %{"scope" => "channels", "channel_ids" => []})
    :ok = perform_job(Worker, %{"transfer_id" => t.id})
    path = Transfers.path(Transfers.get!(t.id))
    assert File.exists?(path)

    assert Transfers.prune(DateTime.add(DateTime.utc_now(), 8 * 24 * 3600)) == 1
    refute File.exists?(path)
    assert %{status: "expired"} = Transfers.get!(t.id)
  end
end
