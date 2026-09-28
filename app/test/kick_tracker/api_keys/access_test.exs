defmodule KickTracker.ApiKeys.AccessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.ApiKeys.Access

  defp key(attrs \\ []) do
    Map.merge(
      %{
        admin: false,
        all_channels: true,
        channel_ids: [],
        group_ids: [],
        scopes: Access.scopes(),
        history_days: nil,
        min_res: nil,
        allowed_cidrs: []
      },
      Map.new(attrs)
    )
  end

  defp channel(id, visibility), do: %{id: id, visibility: visibility}

  describe "channel_access/3" do
    test "a regular key: public fully, live-only live, hidden never" do
      k = key()
      assert Access.channel_access(k, channel(1, :public), []) == :full
      assert Access.channel_access(k, channel(1, :live_only), []) == :live
      assert Access.channel_access(k, channel(1, :hidden), []) == :none
    end

    test "an admin key reaches every channel fully" do
      k = key(admin: true, all_channels: false)

      for v <- [:public, :live_only, :hidden],
          do: assert(Access.channel_access(k, channel(1, v), []) == :full)
    end

    test "a key for chosen channels reaches those listed and those in its groups" do
      k = key(all_channels: false, channel_ids: [1], group_ids: [10])
      assert Access.channel_access(k, channel(1, :public), []) == :full
      assert Access.channel_access(k, channel(2, :public), [10, 11]) == :full
      assert Access.channel_access(k, channel(3, :public), [11]) == :none
      # Listing a hidden channel doesn't reach it.
      assert Access.channel_access(
               key(all_channels: false, channel_ids: [4]),
               channel(4, :hidden),
               []
             ) ==
               :none
    end

    property "a regular key never reaches a hidden channel" do
      check all(
              all? <- boolean(),
              ids <- list_of(integer(1..20)),
              groups <- list_of(integer(1..5)),
              id <- integer(1..20),
              in_groups <- list_of(integer(1..5)),
              scopes <- list_of(member_of(Access.scopes()))
            ) do
        k = key(all_channels: all?, channel_ids: ids, group_ids: groups, scopes: scopes)
        assert Access.channel_access(k, channel(id, :hidden), in_groups) == :none

        for scope <- Access.scopes() ++ ["chat_log"],
            do: refute(Access.can?(k, :none, scope))
      end
    end
  end

  describe "can?/3" do
    test "scopes by access" do
      k = key(scopes: ~w(live viewers))
      assert Access.can?(k, :full, "viewers")
      assert Access.can?(k, :full, "live")
      assert Access.can?(k, :live, "live")
      refute Access.can?(k, :live, "viewers")
      refute Access.can?(k, :full, "chat")
      refute Access.can?(k, :full, "chat_log")
      refute Access.can?(key(scopes: ~w(viewers)), :live, "live")
    end

    test "an admin key reads everything, logged chat included, a regular one never logged chat" do
      assert Access.can?(key(admin: true, scopes: []), :full, "chat_log")
      refute Access.can?(key(scopes: Access.scopes()), :full, "chat_log")
    end
  end

  test "clamp/4 moves the start to the key's history, saying so" do
    now = ~U[2026-09-28 12:00:00Z]
    from = ~U[2026-01-01 00:00:00Z]
    earliest = ~U[2026-08-29 12:00:00Z]

    assert Access.clamp(key(), from, now, now) == {from, now, false}
    assert Access.clamp(key(history_days: 30), from, now, now) == {earliest, now, true}

    # A range wholly before the history becomes empty.
    assert Access.clamp(key(history_days: 30), from, ~U[2026-02-01 00:00:00Z], now) ==
             {earliest, earliest, true}

    assert Access.clamp(key(history_days: 300), from, now, now) == {from, now, false}
  end

  test "resolution/2 is never finer than the key allows" do
    assert Access.resolution(key(), :raw) == :raw
    assert Access.resolution(key(), nil) == nil
    assert Access.resolution(key(min_res: "1h"), :raw) == :hour
    assert Access.resolution(key(min_res: "1h"), nil) == :hour
    assert Access.resolution(key(min_res: "1h"), :day) == :day
  end

  describe "addresses" do
    test "any address without a list, else only those in it" do
      assert Access.address_allowed?(key(), {198, 51, 100, 7})

      k = key(allowed_cidrs: ["203.0.113.0/24", "198.51.100.7", "2001:db8::/32"])
      assert Access.address_allowed?(k, {203, 0, 113, 200})
      assert Access.address_allowed?(k, {198, 51, 100, 7})
      refute Access.address_allowed?(k, {198, 51, 100, 8})
      assert Access.address_allowed?(k, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute Access.address_allowed?(k, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    end

    test "cidr_valid?/1" do
      for ok <- ~w(203.0.113.0/24 198.51.100.7 ::1 2001:db8::/32 0.0.0.0/0),
          do: assert(Access.cidr_valid?(ok), ok)

      for bad <- ~w(203.0.113.0/33 nope 1.2.3/8 2001:db8::/129 1.2.3.4/x 1.2.3.4/8/1),
          do: refute(Access.cidr_valid?(bad), bad)
    end
  end
end
