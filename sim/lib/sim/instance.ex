defmodule Sim.Instance do
  @moduledoc """
  One running fake Kick: its state, its webhook sender and its HTTP server,
  under one supervisor.

  Nothing starts it automatically. `mix sim` starts one, and tests start
  their own, so the recorder tasks (which talk to the real Kick) never bring
  a fake one up by accident.
  """

  use Supervisor

  alias Sim.{Clock, Scenario}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    scenario = Keyword.get(opts, :scenario) || Scenario.new()
    clock = Keyword.get(opts, :clock) || Clock.new()

    children = [
      {Sim.Server, scenario: scenario, clock: clock, pusher: pusher_options(opts, scenario)},
      Sim.Pusher.Hub,
      {Task.Supervisor, name: Sim.Webhooks.Tasks},
      {Sim.Webhooks, webhook_url: Keyword.get(opts, :webhook_url)},
      {Sim.Channels, scenario: scenario, tick_ms: Keyword.get(opts, :tick_ms, 1_000)},
      {Bandit,
       plug: Sim.Http.Router,
       scheme: :http,
       ip: Keyword.get(opts, :ip, :loopback),
       port: Keyword.get(opts, :port, 4050),
       startup_log: Keyword.get(opts, :startup_log, false)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The disconnect fault can come from the scenario or be given directly.
  defp pusher_options(opts, scenario) do
    given = Keyword.get(opts, :pusher, [])

    case Sim.Scenario.fault(scenario, :pusher_disconnect_after_s, nil) do
      nil -> given
      seconds -> Keyword.put_new(given, :disconnect_after_ms, round(seconds * 1000))
    end
  end

  @doc "The Pusher URL to point PUSHER_URL at."
  @spec pusher_url() :: String.t()
  def pusher_url do
    "ws://127.0.0.1:#{port()}/app/#{Sim.Server.pusher().app_key}?protocol=7&client=js&version=8.4.0&flash=false"
  end

  @doc "The port the HTTP server actually listens on (useful when it was given 0)."
  @spec port() :: :inet.port_number()
  def port do
    [pid] =
      for {_id, pid, _type, [Bandit]} <- Supervisor.which_children(__MODULE__), do: pid

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc "The base URL to point KICK_API_URL, KICK_ID_URL and KICK_V2_URL at."
  @spec base_url() :: String.t()
  def base_url, do: "http://127.0.0.1:#{port()}"
end
