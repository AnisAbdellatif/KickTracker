defmodule KickTracker.Tracking.ChannelSup do
  @moduledoc """
  One channel's processes (project.md §10), `rest_for_one`: if the
  `ChannelServer` restarts, what depends on it restarts too; if only a
  later child crashes, the channel's state is untouched.

  Each child reads the channel's row as it is when it (re)starts
  (`Collector.Tracked.get/1`), so a restart never goes back to the row
  as it was when the channel was first started (a chatroom id learnt
  since, a rename). The row given here only stands in when none is known.

  `:temporary` under `Tracking.ChannelsSupervisor`: a channel whose
  processes keep crashing gives up on its own (10 restarts in 60s) without
  spending the restarts of the supervisor all channels share; the
  `Tracking.Manager` notices, and restarts it later with a backoff.
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
      restart: :temporary
    }
  end

  @doc """
  The channel's row as last known (see `Collector.Tracked.get/1`), or
  `fallback` when none is.
  """
  @spec current(Channel.t()) :: Channel.t()
  def current(%Channel{} = fallback),
    do: KickTracker.Collector.Tracked.get(fallback.id) || fallback

  @impl true
  def init(channel) do
    Supervisor.init(children(channel), strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp children(channel) do
    [
      {KickTracker.Tracking.ChannelServer, channel},
      {KickTracker.Tracking.ChatSocket, channel}
    ]
  end
end
