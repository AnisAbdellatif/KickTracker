defmodule KickTracker.ParseChannelEventsMigrationTest do
  @moduledoc """
  Hosts stored as sent, before the parser, are filled and trimmed by the
  migration exactly as `ChannelEvents.row/4` builds new ones.
  """

  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.Repo

  @migration Path.expand(
               "../../priv/repo/migrations/20260926220001_parse_channel_events.exs",
               __DIR__
             )
  @at ~U[2026-01-01 00:00:00.000000Z]

  # A row as the code before the parser stored it.
  defp stored_as_sent(channel_id, {name, pusher_channel, data, at}) do
    %{
      channel_id: channel_id,
      occurred_at: at,
      kind: KickTracker.ChannelEvents.row(name, pusher_channel, data, at).kind,
      other_channel: nil,
      viewers: nil,
      dedup_key: Ecto.UUID.generate(),
      payload: %{"event" => name, "pusher_channel" => pusher_channel, "data" => data}
    }
  end

  defp migrate do
    Code.put_compiler_option(:ignore_module_conflict, true)
    [{module, _}] = Code.compile_file(@migration)
    Code.put_compiler_option(:ignore_module_conflict, false)
    Enum.each(module.statements(), &Repo.query!/1)
  end

  test "stored hosts get what the parser reads, and lose the rest" do
    c = channel!()

    odd = [
      {"App\\Events\\StreamHostEvent", "c", %{"host_username" => "", "number_viewers" => "12"},
       @at},
      {"App\\Events\\StreamHostEvent", "c", %{"number_viewers" => 1.5}, @at},
      {"App\\Events\\StreamHostEvent", nil, "not json", @at},
      {"App\\Events\\ChatMoveToSupportedChannelEvent", "c",
       %{"hosted" => %{"slug" => "somestreamer", "viewers_count" => -3}}, @at},
      {"App\\Events\\ChatMoveToSupportedChannelEvent", "c", %{"hosted" => "x"}, @at}
    ]

    events = recorded_hosts() ++ odd
    Repo.insert_all("channel_events", Enum.map(events, &stored_as_sent(c.id, &1)))

    migrate()
    assert stored() == expected(events)
    assert Enum.count(stored(), &is_integer(&1.viewers)) == 4

    # Running it again changes nothing.
    migrate()
    assert stored() == expected(events)
  end

  defp stored do
    Repo.all(
      from e in "channel_events",
        order_by: e.id,
        select: %{other_channel: e.other_channel, viewers: e.viewers, payload: e.payload}
    )
  end

  defp expected(events) do
    for {n, pc, d, at} <- events do
      row = KickTracker.ChannelEvents.row(n, pc, d, at)
      %{other_channel: row.other_channel, viewers: row.viewers, payload: row.payload}
    end
  end
end
