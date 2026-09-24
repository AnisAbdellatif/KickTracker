defmodule KickTracker.CacheTest do
  # Turns the cache on for itself, so not async.
  use ExUnit.Case, async: false

  alias KickTracker.Cache

  setup do
    Application.put_env(:kick_tracker, :cache, true)
    on_exit(fn -> Application.put_env(:kick_tracker, :cache, false) end)
    Cache.clear()
    :ok
  end

  test "a value is computed once while fresh, and again after a clear" do
    parent = self()
    fun = fn -> send(parent, :computed) && :value end
    assert Cache.fetch(:k, 60, fun) == :value
    assert Cache.fetch(:k, 60, fun) == :value
    assert_received :computed
    refute_received :computed

    Cache.clear()
    Cache.fetch(:k, 60, fun)
    assert_received :computed
  end

  test "an expired value is computed again" do
    parent = self()
    Cache.fetch(:e, 0, fn -> send(parent, :first) end)
    Cache.fetch(:e, 0, fn -> send(parent, :second) end)
    assert_received :first
    assert_received :second
  end

  test "periods reaching into the last two days are cached briefly" do
    assert Cache.ttl_for(DateTime.utc_now()) == 60
    assert Cache.ttl_for(DateTime.add(DateTime.utc_now(), -3, :day)) == 3600
  end
end
