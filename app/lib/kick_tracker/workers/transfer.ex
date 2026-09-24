defmodule KickTracker.Workers.Transfer do
  @moduledoc """
  Runs an export or an import on the collector (see `KickTracker.Transfers`),
  in a queue of its own so a long one never holds up collection jobs.
  After an import it rebuilds the derived tables over the imported range
  (`Workers.Reprocess`), starts tracking the new active channels, and
  carries out the channel removals the other instance recorded.

  `%{"kind" => "prune"}` (daily) deletes old files.
  """

  use Oban.Worker, queue: :transfers, max_attempts: 1

  require Logger
  alias KickTracker.{Cache, Channels, Transfers}
  alias KickTracker.Transfer.{Export, Import}
  alias KickTracker.Workers.{DeleteChannel, Reprocess}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "prune"}}) do
    n = Transfers.prune()
    if n > 0, do: Logger.info("transfers: pruned #{n}")
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  def perform(%Oban.Job{args: %{"transfer_id" => id}}) do
    t = Transfers.get!(id) |> Transfers.start!()

    try do
      run(t)
    rescue
      e ->
        File.rm_rf(Transfers.work_dir(t))
        Logger.error("transfer #{id} failed: " <> Exception.format(:error, e, __STACKTRACE__))
        Transfers.finish!(t, "failed", error: Exception.message(e))
        :ok
    end
  end

  defp run(%{kind: "export", options: o} = t) do
    opts = %{
      scope: if(o["scope"] == "channels", do: :channels, else: :data),
      channel_ids: o["channel_ids"] || [],
      from: parse(o["from"]),
      to: parse(o["to"])
    }

    {:ok, manifest} = Export.run(opts, Transfers.path(t), Transfers.work_dir(t))

    Transfers.finish!(t, "done",
      manifest: manifest,
      size: File.stat!(Transfers.path(t)).size
    )

    :ok
  end

  defp run(%{kind: "import"} = t) do
    case Import.run(Transfers.path(t), Transfers.work_dir(t)) do
      {:ok, summary} ->
        after_import(summary)
        Transfers.finish!(t, "done", summary: summary)

      {:error, reason} ->
        Transfers.finish!(t, "failed", error: reason)
    end

    :ok
  end

  defp after_import(summary) do
    if summary["from"] do
      {:ok, _} =
        Reprocess.enqueue(%{
          "kind" => "rollups",
          "from" => summary["from"],
          "to" => summary["to"]
        })
    end

    for id <- summary["new_channels"] do
      c = Channels.get!(id)
      if c.active, do: Channels.set_active(c, true)
    end

    for id <- summary["delete_channels"] do
      {:ok, _} = DeleteChannel.new(%{"channel_id" => id}) |> Oban.insert()
    end

    Cache.clear()
  end

  defp parse(nil), do: nil

  defp parse(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    at
  end
end
