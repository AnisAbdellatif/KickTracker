defmodule KickTrackerWeb.Admin.TransferController do
  @moduledoc "Serves finished exports to admins (see `KickTracker.Transfers`)."

  use KickTrackerWeb, :controller

  alias KickTracker.{Audit, Transfers}

  # sobelow_skip ["Traversal.SendDownload"]
  def download(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{kind: "export", status: "done"} = t <- KickTracker.Repo.get(Transfers.Transfer, id),
         path = Transfers.path(t),
         true <- File.exists?(path) do
      Audit.log(conn.assigns.current_admin, "transfer.download", "#{t.id}")
      site = conn.assigns[:site_name] || Application.get_env(:kick_tracker, :site_name)
      name = "#{slug(site)}-export-#{Calendar.strftime(t.inserted_at, "%Y%m%d-%H%M")}.zip"
      send_download(conn, {:file, path}, filename: name, content_type: "application/zip")
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
