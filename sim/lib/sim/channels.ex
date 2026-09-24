defmodule Sim.Channels do
  @moduledoc """
  The running channel processes: one per channel in the scenario, each
  under its own supervision, so one misbehaving channel can't stop the
  others from announcing theirs.
  """

  use Supervisor

  alias Sim.Channel.Server, as: ChannelServer
  alias Sim.Scenario

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: Sim.Channel.Registry},
      {DynamicSupervisor, name: Sim.Channels.Supervisor, strategy: :one_for_one},
      {Task, fn -> start_all(opts) end}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts a process for every channel in the scenario."
  @spec start_all(keyword()) :: :ok
  def start_all(opts) do
    scenario = Keyword.get(opts, :scenario) || Sim.Server.scenario()
    for channel <- scenario.channels, do: start_channel(channel, opts)
    :ok
  end

  @doc "Starts one channel's process."
  @spec start_channel(Scenario.Channel.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_channel(channel, opts \\ []) do
    DynamicSupervisor.start_child(
      Sim.Channels.Supervisor,
      {ChannelServer, [channel: channel, tick_ms: Keyword.get(opts, :tick_ms, 1_000)]}
    )
  end

  @doc "Stops one channel's process."
  @spec stop_channel(String.t()) :: :ok | {:error, :not_found}
  def stop_channel(slug) do
    case ChannelServer.whereis(slug) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Sim.Channels.Supervisor, pid)
    end
  end

  @doc "The slugs currently running."
  @spec running() :: [String.t()]
  def running do
    Sim.Channels.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      Registry.keys(Sim.Channel.Registry, pid)
    end)
    |> Enum.sort()
  end
end
