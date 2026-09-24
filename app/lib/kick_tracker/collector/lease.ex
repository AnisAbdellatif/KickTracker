defmodule KickTracker.Collector.Lease do
  @moduledoc """
  The rules of who collects (project.md §10.1), pure: `Collector.Leader`
  carries the state and talks to the database.

  One collector holds the lease at a time, backed by a Postgres advisory
  lock on its own connection. A standby takes it:

    * at once, when the holder released it on shutdown (a deploy);
    * at once, if it is itself the last holder (its own restart);
    * otherwise only when the holder's heartbeat is older than
      `@stale_s` **and** the lock has been seen free for `@confirm_s`:
      a holder whose database connection blipped gets it back first.

  Every change of holder raises the epoch. Writes carry the epoch they
  were made under, and a write made by an older holder after a newer one
  took over is dropped (`stale?/3`): two collectors never both count the
  same chat.
  """

  @stale_s 15
  @confirm_s 5

  @type lease :: %{
          epoch: non_neg_integer(),
          holder: String.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          released_at: DateTime.t() | nil
        }

  @doc "How old a holder's heartbeat must be before a standby may take over."
  def stale_s, do: @stale_s

  @doc """
  Whether `me` may try to take the lease now. `free_since` is when the
  lock was first seen free (nil while it is held).
  """
  @spec may_acquire?(lease | nil, String.t(), DateTime.t(), DateTime.t() | nil) :: boolean()
  def may_acquire?(nil, _me, _now, _free_since), do: true
  def may_acquire?(%{holder: nil}, _me, _now, _free_since), do: true
  def may_acquire?(%{holder: me}, me, _now, _free_since), do: true

  def may_acquire?(lease, _me, now, free_since) do
    released? = lease.released_at != nil
    stale? = lease.heartbeat_at == nil or DateTime.diff(now, lease.heartbeat_at) > @stale_s
    confirmed? = free_since != nil and DateTime.diff(now, free_since) >= @confirm_s
    released? or (stale? and confirmed?)
  end

  @doc """
  Whether a write made under `epoch` at `made_at` must be dropped: a newer
  holder had started by then. `terms` are `{epoch, started_at}`.
  Epoch 0 means "not made under a lease" (tests, tools) and is never
  stale.
  """
  @spec stale?(non_neg_integer(), DateTime.t(), [{non_neg_integer(), DateTime.t()}]) ::
          boolean()
  def stale?(0, _made_at, _terms), do: false

  def stale?(epoch, made_at, terms) do
    case terms
         |> Enum.filter(fn {e, _} -> e > epoch end)
         |> Enum.min_by(&elem(&1, 0), fn -> nil end) do
      nil -> false
      {_, next_started_at} -> not DateTime.before?(made_at, next_started_at)
    end
  end
end
