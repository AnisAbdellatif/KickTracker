defmodule KickTracker.Removals do
  @moduledoc """
  The record of removal requests carried out (project.md §18.3): a Kick
  user's deletion (`KickTracker.Privacy`) or a channel's
  (`Workers.DeleteChannel`). Only the Kick id is kept, so that an import
  (`KickTracker.Transfer.Import`) can't bring back what was removed, and so
  that removals travel with an export to the instance it is imported into.
  """

  alias KickTracker.Repo

  @doc "Records a removal; recording it again changes nothing."
  @spec record(:user | :channel, integer()) :: :ok
  def record(kind, kick_user_id) when kind in [:user, :channel] and is_integer(kick_user_id) do
    Repo.query!(
      "INSERT INTO removals (kind, kick_user_id, removed_at) VALUES ($1, $2, now()) ON CONFLICT DO NOTHING",
      [Atom.to_string(kind), kick_user_id]
    )

    :ok
  end

  @doc """
  Forgets a channel's removal: an admin tracking it again by hand decided
  so, and its history may then be imported again.
  """
  @spec clear_channel(integer()) :: :ok
  def clear_channel(kick_user_id) do
    Repo.query!("DELETE FROM removals WHERE kind = 'channel' AND kick_user_id = $1", [
      kick_user_id
    ])

    :ok
  end
end
