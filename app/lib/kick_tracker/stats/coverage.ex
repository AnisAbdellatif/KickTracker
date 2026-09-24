defmodule KickTracker.Stats.Coverage do
  @moduledoc """
  Our own gaps (project.md §12.5, AGENTS.md §7): for each channel and
  source (`api`, `chat`, `followers`), the periods it was working and the
  ones it wasn't.

  Each outcome extends the channel's latest period for that source if it
  has the same result and the previous one is recent enough (`max_gap_s`,
  a little over the source's cadence); otherwise it starts a new period.
  Periods are always closed (`to_at` is the last outcome seen), so a
  collector that dies leaves no period claiming coverage it didn't have:
  any time no period covers is unknown, and counts as a gap.
  """

  alias KickTracker.Repo

  @doc "Records one outcome for several channels at `at`."
  @spec mark([integer()], String.t(), boolean(), DateTime.t(), pos_integer()) :: :ok
  def mark(channel_ids, source, ok?, at, max_gap_s) do
    for channel_id <- Enum.uniq(channel_ids) do
      %{num_rows: extended} =
        Repo.query!(
          """
          UPDATE coverage SET to_at = $4
          WHERE id = (
            SELECT id FROM coverage
            WHERE channel_id = $1 AND source = $2
            ORDER BY from_at DESC, id DESC LIMIT 1
          )
          AND ok = $3 AND to_at >= $4::timestamptz - make_interval(secs => $5::int) AND to_at <= $4::timestamptz
          """,
          [channel_id, source, ok?, at, max_gap_s]
        )

      if extended == 0 do
        Repo.query!(
          "INSERT INTO coverage (channel_id, source, from_at, to_at, ok) VALUES ($1, $2, $3, $3, $4)",
          [channel_id, source, at, ok?]
        )
      end
    end

    :ok
  end
end
