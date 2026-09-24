defmodule KickTracker.Corrections do
  @moduledoc """
  Stream corrections (project.md §13.8), layered on the raw streams and
  never editing them: **exclude** a stream from every figure (a test
  stream, a rebroadcast), or **merge** a stream into the one before it
  (the sessionizer split one broadcast in two). Revoking keeps the row.

  The web role writes these (admin tables) and queues the collector's
  `Workers.Reprocess` to recompute the figures they change.
  """

  import Ecto.Query
  alias KickTracker.{Audit, Cache, Repo}
  alias KickTracker.Workers.Reprocess

  @doc "A channel's corrections, newest first."
  @spec list(integer()) :: [map()]
  def list(channel_id) do
    Repo.query!(
      """
      SELECT o.id, o.kind, o.stream_id, s.started_at, o.other_stream_id, os.started_at, o.note,
             o.inserted_at, o.revoked_at, a.email
      FROM stream_overrides o
      JOIN streams s ON s.id = o.stream_id
      LEFT JOIN streams os ON os.id = o.other_stream_id
      LEFT JOIN admins a ON a.id = o.admin_id
      WHERE s.channel_id = $1
      ORDER BY o.inserted_at DESC
      """,
      [channel_id]
    ).rows
    |> Enum.map(fn [id, kind, sid, s_at, oid, o_at, note, at, revoked, by] ->
      %{
        id: id,
        kind: kind,
        stream_id: sid,
        stream_at: s_at,
        other_stream_id: oid,
        other_at: o_at,
        note: note,
        at: at,
        revoked_at: revoked,
        by: by
      }
    end)
  end

  @doc "Excludes a stream from statistics."
  @spec exclude(integer(), String.t(), map()) :: {:ok, integer()} | {:error, String.t()}
  def exclude(stream_id, note, admin) do
    with {:ok, stream} <- fetch_stream(stream_id),
         :ok <- not_already(stream_id, "exclude") do
      insert(%{kind: "exclude", stream_id: stream_id}, note, admin, [stream])
    end
  end

  @doc """
  Merges `other_id` into `stream_id`: the same channel, and the next
  stream after it (nothing in between).
  """
  @spec merge(integer(), integer(), String.t(), map()) :: {:ok, integer()} | {:error, String.t()}
  def merge(stream_id, other_id, note, admin) do
    with {:ok, a} <- fetch_stream(stream_id),
         {:ok, b} <- fetch_stream(other_id),
         :ok <- mergeable(a, b) do
      insert(%{kind: "merge", stream_id: stream_id, other_stream_id: other_id}, note, admin, [
        a,
        b
      ])
    end
  end

  @doc "Revokes a correction; the figures are recomputed."
  @spec revoke(integer(), map()) :: :ok | {:error, String.t()}
  def revoke(id, admin) do
    case Repo.query!(
           "UPDATE stream_overrides SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL RETURNING kind, stream_id, other_stream_id",
           [id]
         ).rows do
      [[kind, sid, oid]] ->
        streams = for id <- [sid, oid], id, {:ok, s} = fetch_stream(id), do: s
        recompute(streams)
        Audit.log(admin, "correction.revoke", "#{kind} #{sid}", %{"id" => id})
        :ok

      [] ->
        {:error, "no such correction"}
    end
  end

  defp insert(fields, note, admin, streams) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO stream_overrides (kind, stream_id, other_stream_id, note, admin_id, inserted_at)
        VALUES ($1, $2, $3, $4, $5, now()) RETURNING id
        """,
        [
          fields.kind,
          fields.stream_id,
          fields[:other_stream_id],
          blank_to_nil(note),
          admin && admin.id
        ]
      )

    recompute(streams)

    Audit.log(
      admin,
      "correction.#{fields.kind}",
      "#{fields.stream_id}",
      Map.new(fields, fn {k, v} -> {to_string(k), v} end)
    )

    {:ok, id}
  end

  # The figures the correction changes: the streams' own, and the hours they cover.
  defp recompute(streams) do
    from = streams |> Enum.map(& &1.started_at) |> Enum.min(DateTime)
    to = streams |> Enum.map(&(&1.ended_at || DateTime.utc_now())) |> Enum.max(DateTime)

    Reprocess.enqueue(%{
      "kind" => "rollups",
      "from" => DateTime.to_iso8601(from),
      "to" => DateTime.to_iso8601(to),
      "stream_ids" => Enum.map(streams, & &1.id)
    })

    Cache.clear()
  end

  defp fetch_stream(id) do
    case Repo.one(
           from s in "streams",
             where: s.id == ^id,
             select: %{
               id: s.id,
               channel_id: s.channel_id,
               started_at: s.started_at,
               ended_at: s.ended_at
             }
         ) do
      nil -> {:error, "no stream #{id}"}
      s -> {:ok, s}
    end
  end

  defp not_already(stream_id, kind) do
    if Repo.exists?(
         from o in "stream_overrides",
           where: o.stream_id == ^stream_id and o.kind == ^kind and is_nil(o.revoked_at)
       ),
       do: {:error, "already #{kind}d"},
       else: :ok
  end

  defp mergeable(a, b) do
    between? =
      Repo.exists?(
        from s in "streams",
          where:
            s.channel_id == ^a.channel_id and s.started_at > ^a.started_at and
              s.started_at < ^b.started_at
      )

    cond do
      a.channel_id != b.channel_id ->
        {:error, "streams of different channels"}

      DateTime.compare(b.started_at, a.started_at) != :gt ->
        {:error, "merge a stream into the one before it"}

      between? ->
        {:error, "another stream lies between them"}

      Repo.exists?(from m in "merged_streams", where: m.other_stream_id == ^b.id) ->
        {:error, "already merged"}

      true ->
        :ok
    end
  end

  defp blank_to_nil(s) when s in [nil, ""], do: nil
  defp blank_to_nil(s), do: String.trim(s)
end
