defmodule KickTracker.Transfers do
  @moduledoc """
  Exports and imports requested from the admin (project.md §13.8): their
  log (`transfers`) and their files in `TRANSFER_DIR`, which the web and
  collector roles share. The web role writes the requests and serves the
  files; the collector does the work (`Workers.Transfer`), since only it
  writes collected data.

  An import is uploaded first (status `uploaded`, manifest read for a
  preview), then confirmed (`queued`). Files are kept for 7 days.
  """

  import Ecto.Query
  alias KickTracker.{Audit, Repo}
  alias KickTracker.Transfer.Import
  alias KickTracker.Transfers.Transfer
  alias KickTracker.Workers.Transfer, as: Worker

  @keep_days 7

  @doc "Where the files live."
  @spec dir() :: Path.t()
  # sobelow_skip ["Traversal.FileModule"]
  def dir do
    dir = Application.fetch_env!(:kick_tracker, :transfer_dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc "The archive of a transfer, named by its id only."
  @spec path(Transfer.t()) :: Path.t()
  def path(%Transfer{id: id, kind: kind}), do: Path.join(dir(), "#{kind}-#{id}.zip")

  @doc "Where a transfer unpacks or gathers its CSVs."
  @spec work_dir(Transfer.t()) :: Path.t()
  def work_dir(%Transfer{id: id}), do: Path.join(dir(), "work-#{id}")

  @doc "The most recent transfers."
  @spec list(pos_integer()) :: [Transfer.t()]
  def list(limit \\ 20),
    do: Repo.all(from t in Transfer, order_by: [desc: t.id], limit: ^limit, preload: :admin)

  @spec get!(integer()) :: Transfer.t()
  def get!(id), do: Repo.get!(Transfer, id)

  @doc """
  Queues an export. `options`: `"scope"` (`"channels"` or `"data"`),
  `"channel_ids"`, `"from"` and `"to"` (ISO 8601, optional).
  """
  @spec request_export(struct() | nil, map()) :: {:ok, Transfer.t()}
  def request_export(admin, options) do
    Repo.transaction(fn ->
      t =
        Repo.insert!(%Transfer{
          kind: "export",
          status: "queued",
          options: options,
          admin_id: admin && admin.id
        })

      {:ok, _} = Worker.new(%{"transfer_id" => t.id}) |> Oban.insert()
      Audit.log(admin, "transfer.export", "#{t.id}", options)
      t
    end)
  end

  @doc """
  Takes an uploaded file: keeps it and reads its manifest for a preview.
  An unreadable one is recorded as failed, with the reason.
  """
  @spec upload_import(struct() | nil, Path.t()) :: {:ok, Transfer.t()} | {:error, Transfer.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def upload_import(admin, upload_path) do
    t = Repo.insert!(%Transfer{kind: "import", status: "uploaded", admin_id: admin && admin.id})
    File.cp!(upload_path, path(t))
    size = File.stat!(path(t)).size

    case Import.read_manifest(path(t)) do
      {:ok, manifest, _files} ->
        manifest = Map.update!(manifest, "exported_at", &DateTime.to_iso8601/1)
        {:ok, update!(t, manifest: manifest, size: size)}

      {:error, reason} ->
        File.rm(path(t))
        {:error, finish!(t, "failed", error: reason, size: size)}
    end
  end

  @doc """
  What an uploaded import would do here, from its manifest: which channels
  are new, which are tracked already, and which tracked channels the
  other instance deleted on a removal request (they'd be deleted here too).
  """
  @spec preview(Transfer.t()) :: map()
  def preview(%Transfer{manifest: m}) do
    ids = Enum.map(m["channels"], & &1["kick_user_id"])
    here = Repo.all(from c in "channels", where: c.kick_user_id in ^ids, select: c.kick_user_id)

    removed_here =
      Repo.all(
        from r in "removals",
          where: r.kind == "channel" and r.kick_user_id in ^ids,
          select: r.kick_user_id
      )

    to_delete =
      Repo.all(
        from c in "channels",
          where: c.kick_user_id in ^(m["removed_channels"] || []),
          select: c.slug,
          order_by: c.slug
      )

    {existing, new} = Enum.split_with(m["channels"], &(&1["kick_user_id"] in here))

    %{
      new: Enum.reject(new, &(&1["kick_user_id"] in removed_here)),
      existing: existing,
      skipped: Enum.filter(new, &(&1["kick_user_id"] in removed_here)),
      delete: to_delete
    }
  end

  @doc "Queues an uploaded import."
  @spec confirm_import(struct() | nil, Transfer.t()) ::
          {:ok, Transfer.t()} | {:error, :not_uploaded}
  def confirm_import(admin, %Transfer{kind: "import", status: "uploaded"} = t) do
    Repo.transaction(fn ->
      t = update!(t, status: "queued")
      {:ok, _} = Worker.new(%{"transfer_id" => t.id}) |> Oban.insert()

      Audit.log(admin, "transfer.import", "#{t.id}", %{
        "channels" => length(t.manifest["channels"])
      })

      t
    end)
  end

  def confirm_import(_, _), do: {:error, :not_uploaded}

  @doc "Drops an uploaded import that wasn't confirmed."
  @spec cancel_import(Transfer.t()) :: Transfer.t()
  # sobelow_skip ["Traversal.FileModule"]
  def cancel_import(%Transfer{kind: "import", status: "uploaded"} = t) do
    File.rm(path(t))
    finish!(t, "expired")
  end

  @doc "Marks a transfer as running."
  def start!(t), do: update!(t, status: "running")

  @doc ~s(Ends a transfer: "done", "failed" or "expired", with more fields.)
  def finish!(t, status, fields \\ []),
    do: update!(t, [status: status, finished_at: DateTime.utc_now()] ++ fields)

  @doc "Deletes files older than #{@keep_days} days and marks their transfers expired."
  @spec prune(DateTime.t()) :: non_neg_integer()
  # sobelow_skip ["Traversal.FileModule"]
  def prune(now \\ DateTime.utc_now()) do
    before = DateTime.add(now, -@keep_days * 24 * 3600)

    old =
      Repo.all(
        from t in Transfer,
          where: t.inserted_at < ^before and t.status in ["uploaded", "done", "failed"]
      )

    for t <- old do
      File.rm(path(t))
      File.rm_rf(work_dir(t))
      update!(t, status: "expired")
    end

    length(old)
  end

  defp update!(t, fields), do: t |> Ecto.Changeset.change(fields) |> Repo.update!()
end
