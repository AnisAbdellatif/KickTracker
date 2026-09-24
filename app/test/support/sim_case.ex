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

  @doc "Starts the collector's processes, except the queue consumer."
  def start_collector(opts \\ []) do
    start = &ExUnit.Callbacks.start_supervised!/1
    start.({Registry, keys: :unique, name: KickTracker.Tracking.registry()})
    start.(KickTracker.Kick.Token)

    start.(
      {DynamicSupervisor, name: KickTracker.Tracking.ChannelsSupervisor, strategy: :one_for_one}
    )

    start.(
      {KickTracker.Tracking.Manager, on_change: Keyword.get(opts, :on_change, fn -> :ok end)}
    )

    start.({KickTracker.Tracking.Poller, interval_ms: 0})
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
