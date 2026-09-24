defmodule KickTracker.Collector.Remote do
  @moduledoc """
  A short-lived connection to the other side's database (project.md
  §10.5): the primary side reading the shadow's data to fill its gaps, the
  shadow reading the primary's channel list and removals. Over a private
  network, with a read-only user; never through the Repo.
  """

  @doc """
  Connects to `url` (an `ecto://` URL), runs `fun` with a query function
  `(sql, params) -> rows`, and disconnects. `{:ok, result}`, or `{:error,
  reason}` when the other side can't be reached or a query fails.
  """
  @spec with_conn(String.t(), ((String.t(), list() -> list()) -> term())) ::
          {:ok, term()} | {:error, term()}
  def with_conn(url, fun) do
    opts =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.merge(pool_size: 1, connect_timeout: 10_000, queue_target: 5_000)

    {:ok, conn} = Postgrex.start_link(opts)

    try do
      query = fn sql, params -> Postgrex.query!(conn, sql, params, timeout: 60_000).rows end
      {:ok, fun.(query)}
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    after
      Process.unlink(conn)
      GenServer.stop(conn, :normal)
    end
  end
end
