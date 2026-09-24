defmodule KickTracker.Workers.SubscriptionSyncTest do
  use ExUnit.Case, async: true

  alias KickTracker.Workers.SubscriptionSync

  defp sub(id, user, event), do: %{"id" => id, "broadcaster_user_id" => user, "event" => event}

  test "subscribes what's missing, removes what's untracked or doubled, keeps the rest" do
    [first | rest] = SubscriptionSync.events()

    existing =
      [
        sub("a", 1, first),
        sub("b", 1, first),
        sub("c", 2, first),
        sub("d", 1, "moderation.banned")
      ] ++
        for {e, i} <- Enum.with_index(SubscriptionSync.events()), do: sub("x#{i}", 3, e)

    {create, delete} = SubscriptionSync.plan([%{kick_user_id: 1}, %{kick_user_id: 3}], existing)

    # Channel 1 keeps its first subscription (the older id) and gets the rest;
    # channel 3 is complete.
    assert create == [{1, Enum.sort(rest)}]
    # The duplicate, the untracked channel's and the unused event type go.
    assert Enum.sort(delete) == ["b", "c", "d"]
  end

  test "Kick cancelling a channel's subscriptions brings them back" do
    {create, []} = SubscriptionSync.plan([%{kick_user_id: 7}], [])
    assert create == [{7, Enum.sort(SubscriptionSync.events())}]
  end
end
