defmodule KickTracker.Fixtures do
  @moduledoc "Rows for tests, with obviously fake values."

  alias KickTracker.Channels.Channel
  alias KickTracker.Repo

  @doc "A tracked channel."
  def channel!(attrs \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Channel{
      kick_user_id: Keyword.get(attrs, :kick_user_id, 1_000_000 + n),
      slug: Keyword.get(attrs, :slug, "somestreamer#{n}"),
      chatroom_id: Keyword.get(attrs, :chatroom_id),
      active: Keyword.get(attrs, :active, true)
    })
  end

  @doc "All rows of a table as maps, ordered by the given columns."
  def rows(table, order_by) do
    %{columns: cols, rows: rows} =
      Repo.query!("SELECT * FROM #{table} ORDER BY #{Enum.join(order_by, ", ")}")

    Enum.map(rows, fn row -> cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new() end)
  end
end
