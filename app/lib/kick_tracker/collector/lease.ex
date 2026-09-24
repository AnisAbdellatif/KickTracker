defmodule KickTracker.Collector.Lease do
  @moduledoc """
  The rules of who collects (project.md §10.1), pure: `Collector.Leader`
  carries the state and talks to the database.

  One collector holds the lease at a time, backed by a Postgres advisory
  lock on its own connection, and heartbeats every second. What a standby
  does (`decide/3`), from what it observes — all times are the
  database's, so the machines' clocks don't matter:

    * the lease released on a clean stop (a deploy), unheld, or last held
      by this node itself: **take it**;
    * the lock free and the database **not** restarted since the holder's
      last heartbeat: the holder's session ended (it crashed or was
      killed), so **take it at once**;
    * the lock free because the database restarted: give the holder
      `grace_s` to reconnect and take its lock back, and take it only if
      it doesn't (and the lock has been free for `confirm_s`);
    * the lock held but the holder silent for `unresponsive_s` (frozen,
      or cut off with its connection half-open, which TCP may take hours
      to notice): **end the holder's session**, then take it;
    * otherwise wait.

  Every change of holder raises the epoch. Writes carry the epoch they
  were made under, and a write made by an older holder after a newer one
  took over is dropped (`stale?/3`): a leader cut off but still
  collecting can't double anything when it comes back.
  """

  @defaults %{unresponsive_s: 6, grace_s: 10, confirm_s: 3}

  @type lease :: %{
          epoch: non_neg_integer(),
          holder: String.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          released_at: DateTime.t() | nil
        }
  @type observation :: %{
          now: DateTime.t(),
          lock_free?: boolean(),
          free_since: DateTime.t() | nil,
          db_started_at: DateTime.t()
        }

  @doc "The thresholds, in seconds."
  def defaults, do: @defaults

  @doc "What a standby named `me` should do: `:acquire`, `:terminate` (the holder's session) or `:wait`."
  @spec decide(lease() | nil, String.t(), observation(), map()) :: :acquire | :terminate | :wait
  def decide(lease, me, obs, limits \\ @defaults) do
    limits = Map.merge(@defaults, limits)
    silent_s = lease && lease.heartbeat_at && DateTime.diff(obs.now, lease.heartbeat_at)
    unresponsive? = silent_s == nil or silent_s > limits.unresponsive_s

    cond do
      nil_or_free_to_take?(lease, me) -> free_lease(obs, unresponsive?)
      obs.lock_free? -> lock_free(lease, obs, silent_s, limits)
      unresponsive? -> :terminate
      true -> :wait
    end
  end

  # Nobody's, released, or our own: the lock decides. A lock still held by
  # a session that stopped heartbeating (our own earlier one, say) is ended.
  defp free_lease(%{lock_free?: true}, _unresponsive?), do: :acquire
  defp free_lease(_obs, true), do: :terminate
  defp free_lease(_obs, false), do: :wait

  # The holder's lock is gone: its session ended (take over), unless the
  # database restarted, in which case it gets time to take it back.
  defp lock_free(lease, obs, silent_s, limits) do
    confirmed? =
      obs.free_since != nil and DateTime.diff(obs.now, obs.free_since) >= limits.confirm_s

    cond do
      ended_without_restart?(lease, obs) -> :acquire
      confirmed? and (silent_s == nil or silent_s > limits.grace_s) -> :acquire
      true -> :wait
    end
  end

  defp nil_or_free_to_take?(nil, _me), do: true
  defp nil_or_free_to_take?(%{holder: nil}, _me), do: true
  defp nil_or_free_to_take?(%{holder: me}, me), do: true
  defp nil_or_free_to_take?(%{released_at: released}, _me), do: released != nil

  # The holder's lock went away while the database kept running: its
  # session ended, it isn't coming back to it.
  defp ended_without_restart?(%{heartbeat_at: nil}, _obs), do: true

  defp ended_without_restart?(%{heartbeat_at: hb}, %{db_started_at: started}),
    do: DateTime.before?(started, hb)

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
