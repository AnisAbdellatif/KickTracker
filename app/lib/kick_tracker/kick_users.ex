defmodule KickTracker.KickUsers do
  @moduledoc """
  `kick_users`: the only place usernames are kept (project.md §12.7).
  Facts everywhere else hold Kick user ids, so a removal request touches
  this table and the raw event bodies, nothing else.
  """

  import Ecto.Query

  alias KickTracker.Repo

  @doc """
  Records users as `{id, username, seen_at}`. A username seen later
  replaces an earlier one (people rename); an earlier sighting arriving
  late doesn't.
  """
  @spec upsert([{integer(), String.t(), DateTime.t()}]) :: :ok
  def upsert([]), do: :ok

  def upsert(users) do
    rows =
      users
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {id, sightings} ->
        {_, username, seen_at} = Enum.max_by(sightings, &elem(&1, 2), DateTime)
        %{id: id, username: username, seen_at: seen_at}
      end)

    Repo.insert_all("kick_users", rows,
      on_conflict:
        from(u in "kick_users",
          update: [
            set: [
              username:
                fragment(
                  "CASE WHEN EXCLUDED.seen_at >= ? THEN EXCLUDED.username ELSE ? END",
                  u.seen_at,
                  u.username
                ),
              seen_at: fragment("GREATEST(EXCLUDED.seen_at, ?)", u.seen_at)
            ]
          ]
        ),
      conflict_target: :id
    )

    :ok
  end
end
