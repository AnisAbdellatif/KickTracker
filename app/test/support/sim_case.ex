defmodule KickTracker.SimCase do
  @moduledoc """
  Tests against the fake Kick (`../sim`): starts one on a free port with
  the given scenario and points the app's Kick configuration at it, so the
  code under test runs exactly as it would against the real Kick
  (AGENTS.md §6). Not async: there is one fake Kick at a time.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use KickTracker.DataCase, async: false
      import KickTracker.SimCase
    end
  end

  @doc "Starts the fake Kick with these channel specs; returns its base URL."
  def start_sim(channels, opts \\ []) do
    scenario =
      Sim.Scenario.new(seed: 7, channels: channels, faults: Keyword.get(opts, :faults, []))

    ExUnit.Callbacks.start_supervised!(
      {Sim.Instance,
       scenario: scenario,
       port: 0,
       tick_ms: Keyword.get(opts, :tick_ms, 60_000),
       webhook_url: opts[:webhook_url]}
    )

    base = Sim.Instance.base_url()
    previous = Application.get_env(:kick_tracker, :kick)

    Application.put_env(
      :kick_tracker,
      :kick,
      Keyword.merge(previous,
        api_url: base,
        id_url: base,
        v2_url: base <> "/api/v2",
        pusher_url: Sim.Instance.pusher_url(),
        public_key: Sim.Server.public_key_pem()
      )
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kick_tracker, :kick, previous) end)
    base
  end

  @doc "Calls the fake Kick's control API (`/_sim`)."
  def sim_ctl(method, path, body \\ nil) do
    opts = [method: method, url: Sim.Instance.base_url() <> "/_sim" <> path, retry: false]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts
    Req.request!(opts)
  end

  @doc """
  Starts the collection processes, except the queue consumer, without the
  leader election (`Collector.Collection` runs them in production). The
  sources don't run on their own: `poll/1` and `run_source/1` run them.
  """
  def start_collector(opts \\ []) do
    start = &ExUnit.Callbacks.start_supervised!/1
    start.(KickTracker.Collector.Status)
    start.({Registry, keys: :unique, name: KickTracker.Tracking.registry()})
    start.({Task.Supervisor, name: KickTracker.Collector.Tasks})
    start.(KickTracker.Kick.Token)

    start.(
      {DynamicSupervisor, name: KickTracker.Tracking.ChannelsSupervisor, strategy: :one_for_one}
    )

    start.(
      {KickTracker.Tracking.Manager, on_change: Keyword.get(opts, :on_change, fn -> :ok end)}
    )

    for source <- [
          KickTracker.Collector.Sources.Viewers,
          KickTracker.Collector.Sources.Subscribers,
          KickTracker.Collector.Sources.Followers
        ],
        do: start.({KickTracker.Collector.SourceRunner, {source, first_ms: nil}})

    :ok
  end

  @doc "Runs one cycle of a source now."
  def run_source(source), do: KickTracker.Collector.SourceRunner.run_now(source)

  @doc """
  Polls now (viewers, and subscriber totals too with `channels: true`),
  then waits until every channel's process has handled what the poll sent
  it (a call is answered only after earlier messages).
  """
  def poll(opts \\ []) do
    run_source(KickTracker.Collector.Sources.Viewers)
    if opts[:channels], do: run_source(KickTracker.Collector.Sources.Subscribers)
    settle()
  end

  @doc "Waits until every running channel process has handled its mailbox."
  def settle do
    for {_, pid, _} <-
          Registry.select(KickTracker.Tracking.registry(), [
            {{{:channel, :_}, :"$1", :_}, [], [{{nil, :"$1", nil}}]}
          ]),
        do: KickTracker.Tracking.ChannelServer.info(pid)

    :ok
  end

  @doc "Waits until `fun` returns truthy (up to ~5s); returns its last value."
  def eventually(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end
end
