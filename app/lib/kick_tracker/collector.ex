defmodule KickTracker.Collector do
  @moduledoc """
  Collection that doesn't stop (project.md §10.1, §10.2).

  Any number of collector nodes run; one leads, the others stand by
  (`Collector.Leader`, `Collector.Lease`). Only the leader collects: its
  `Collector.Collection` tree polls Kick through the `Collector.Source`s,
  runs the channel processes and chat sockets, and consumes webhook
  events. Every write goes to a local `Collector.Journal` first and
  reaches Postgres through `Collector.Writer`, so the database being away
  delays writes instead of stopping collection.

  This module holds the node's identity and its view of the lease.
  """

  @doc "This collector's name: `COLLECTOR_ID`, or the host name."
  @spec id() :: String.t()
  def id, do: config(:id) || hostname()

  @doc "`:primary`, or `:shadow` for an independent collector on another machine (§10.5)."
  @spec mode() :: :primary | :shadow
  def mode, do: config(:mode, :primary)

  @doc "The lease all collectors of this deployment contend for."
  @spec lease_name() :: String.t()
  def lease_name, do: config(:lease, "collector")

  @doc "The epoch this node collects under (0 when it has never led)."
  @spec epoch() :: non_neg_integer()
  def epoch, do: :persistent_term.get({__MODULE__, :epoch}, 0)

  @doc "Whether this node is the one collecting."
  @spec leader?() :: boolean()
  def leader?, do: :persistent_term.get({__MODULE__, :leader}, false)

  @doc false
  def put_leadership(leader?, epoch) do
    :persistent_term.put({__MODULE__, :leader}, leader?)
    if epoch, do: :persistent_term.put({__MODULE__, :epoch}, epoch)
    :ok
  end

  @doc "A channel's process here, by Kick broadcaster id, or nil."
  @spec channel_pid(integer()) :: pid() | nil
  def channel_pid(kick_user_id), do: KickTracker.Tracking.whereis({:channel, kick_user_id})

  @doc """
  How this node is doing: its role and epoch, the journal, the writer and
  each source. What the status endpoint answers and the heartbeat row
  holds.
  """
  @spec status() :: map()
  def status do
    s = KickTracker.Collector.Status.all()
    journal = KickTracker.Collector.Journal.stats()

    %{
      id: id(),
      role: if(leader?(), do: "leader", else: "standby"),
      epoch: epoch(),
      leader: s[:leader],
      loop_at: s[:leader_loop_at],
      journal: journal,
      writer: s[:writer],
      sources: for({{:source, name}, v} <- s, into: %{}, do: {name, v}),
      # Channels whose processes kept crashing, waiting to be restarted
      # (`Tracking.Manager`).
      quarantined:
        for(
          {id, q} <- s[:quarantined_channels] || %{},
          do: %{channel_id: id, failures: q.failures, since: q.since}
        ),
      version: to_string(Application.spec(:kick_tracker, :vsn)),
      build: KickTracker.build()
    }
  end

  @doc """
  Whether this node works (the container healthcheck): a leader whose
  viewers source completed a cycle recently (or that only just started
  leading), or a standby whose lease checks are running.
  """
  @spec healthy?(map(), DateTime.t()) :: boolean()
  def healthy?(status, now \\ DateTime.utc_now()) do
    recent? = fn at, s -> at != nil and DateTime.diff(now, at) <= s end

    case status.role do
      "leader" ->
        recent?.(get_in(status, [:sources, :viewers, :cycle_at]), 180) or
          recent?.(get_in(status, [:leader, :since]), 180)

      _ ->
        recent?.(status.loop_at, 30)
    end
  end

  @doc "A setting of `:kick_tracker, :collector`."
  def config(key, default \\ nil),
    do: Keyword.get(Application.get_env(:kick_tracker, :collector, []), key, default)

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
