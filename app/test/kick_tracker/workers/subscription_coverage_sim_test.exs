defmodule KickTracker.Workers.SubscriptionCoverageSimTest do
  @moduledoc """
  Ingress coverage from the subscription check, against the fake Kick:
  what makes webhook counts (follows, subs, gifts, Kicks) 0 rather than
  unknown.
  """

  use KickTracker.SimCase
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Channels
  alias KickTracker.Tracking.Manager
  alias KickTracker.Workers.SubscriptionSync

  setup do
    start_sim([[slug: "offlinestreamer", schedule: :never]])
    start_collector()
    {:ok, c} = Channels.add("offlinestreamer")
    Manager.sync()
    %{c: c}
  end

  test "a channel whose subscriptions are in place is covered, and each check extends it", %{
    c: c
  } do
    :ok = SubscriptionSync.perform(%Oban.Job{})
    assert [%{source: "ingress", ok: true, from_at: first}] = ingress(c)

    :ok = SubscriptionSync.perform(%Oban.Job{})
    assert [%{ok: true, from_at: ^first, to_at: to}] = ingress(c)
    assert DateTime.compare(to, first) == :gt
  end

  defp ingress(c),
    do:
      rows("coverage", ["id"]) |> Enum.filter(&(&1.channel_id == c.id and &1.source == "ingress"))
end
