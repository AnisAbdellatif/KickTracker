defmodule KickTracker.Tracking.ChannelSup do
  @moduledoc """
  One channel's processes (project.md §10), `rest_for_one`: if the
  `ChannelServer` restarts, what depends on it restarts too; if only a
  later child crashes, the channel's state is untouched.
  """

  use Supervisor

  alias KickTracker.Channels.Channel

  @spec start_link(Channel.t()) :: Supervisor.on_start()
  def start_link(%Channel{} = channel),
    do:
      Supervisor.start_link(__MODULE__, channel,
        name: KickTracker.Tracking.via({:channel_sup, channel.id})
      )

  def child_spec(%Channel{} = channel) do
    %{
      id: {__MODULE__, channel.id},
      start: {__MODULE__, :start_link, [channel]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @impl true
  def init(channel) do
    Supervisor.init(children(channel), strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp children(channel) do
    [{KickTracker.Tracking.ChannelServer, channel}]
  end
end
