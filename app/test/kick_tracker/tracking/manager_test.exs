defmodule KickTracker.Tracking.ManagerTest do
  @moduledoc """
  One channel whose processes keep crashing can't take the others, or the
  supervisor they share, down: it is quarantined and retried with a
  backoff.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Collector.Status
  alias KickTracker.Tracking
  alias KickTracker.Tracking.{ChannelSup, Manager}

  # Stands in for a channel's `ChannelSup`: its one process crashes at
  # once, again and again, for a channel whose slug says so (as a poison
  # event replayed at every start would), and runs quietly otherwise.
  defmodule FlakySup do
    @moduledoc false
    use Supervisor

    def start_link(channel),
      do:
        Supervisor.start_link(__MODULE__, channel, name: Tracking.via({:channel_sup, channel.id}))

    def child_spec(channel),
      do: %{
        id: {__MODULE__, channel.id},
        start: {__MODULE__, :start_link, [channel]},
        type: :supervisor,
        restart: :temporary
      }

    @impl true
    def init(channel) do
      work = fn ->
        if String.starts_with?(channel.slug, "crashing"),
          do: raise("poison"),
          else: Process.sleep(:infinity)
      end

      Supervisor.init([Supervisor.child_spec({Task, work}, restart: :permanent)],
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 60
      )
    end
  end

  setup do
    start_supervised!(Status)
    start_supervised!({Registry, keys: :unique, name: Tracking.registry()})

    # The same limits as in production (`Collector.Collection`).
    start_supervised!(
      {DynamicSupervisor,
       name: Tracking.ChannelsSupervisor,
       strategy: :one_for_one,
       max_restarts: 100,
       max_seconds: 60}
    )

    :ok
  end

  defp sup(channel), do: Tracking.whereis({:channel_sup, channel.id})

  test "a crash-looping channel is quarantined and retried later; the others never notice" do
    good = channel!(slug: "goodstreamer")
    bad = channel!(slug: "crashingstreamer")

    manager =
      start_supervised!(
        {Manager, child: FlakySup, base_backoff_ms: 1_000, on_change: fn -> :ok end}
      )

    good_sup = eventually(fn -> sup(good) end)

    assert %{failures: 1} = eventually(fn -> Manager.quarantined(manager)[bad.id] end)
    assert Status.get(:quarantined_channels)[bad.id].failures == 1

    # A sync within the backoff leaves it stopped.
    Manager.sync(manager)
    assert sup(bad) == nil

    # After it, it is tried again, fails again, and waits twice as long.
    assert %{failures: 2} =
             eventually(fn ->
               q = Manager.quarantined(manager)[bad.id]
               q && q.failures == 2 && q
             end)

    # The other channel's processes were never touched, nor the shared
    # supervisor.
    assert sup(good) == good_sup
    assert Process.alive?(good_sup)
    assert Process.alive?(Process.whereis(Tracking.ChannelsSupervisor))
    assert Process.alive?(manager)
  end

  test "a channel's processes are started from the row as it is, and are temporary" do
    assert %{restart: :temporary} = ChannelSup.child_spec(%KickTracker.Channels.Channel{id: 1})
    c = channel!()
    KickTracker.Channels.store_ids(c.id, 5, 6)
    assert %{chatroom_id: 6, kick_channel_id: 5} = ChannelSup.current(c)
  end

  test "stopping a channel waits for its processes, and it isn't counted as a failure" do
    c = channel!()
    manager = start_supervised!({Manager, child: FlakySup, on_change: fn -> :ok end})
    pid = eventually(fn -> sup(c) end)

    Repo.query!("UPDATE channels SET active = false WHERE id = $1", [c.id])
    :ok = Manager.stop_channel(c.id, manager)

    refute Process.alive?(pid)
    assert Manager.quarantined(manager) == %{}
  end

  defp eventually(fun, tries \\ 200) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(25)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end
end
