defmodule KickTracker.RoleTest do
  use ExUnit.Case, async: true
  doctest KickTracker.Role

  alias KickTracker.Role

  test "either role, both in any order, spaces and repeats tolerated" do
    assert Role.parse("collector") == {:ok, [:collector]}
    assert Role.parse("web") == {:ok, [:web]}
    assert Role.parse("web,collector") == {:ok, [:collector, :web]}
    assert Role.parse("collector, web, web") == {:ok, [:collector, :web]}
  end

  test "an empty or unknown role is an error, so a typo stops the node at boot" do
    assert {:error, "ROLE is empty" <> _} = Role.parse("")
    assert {:error, "ROLE is empty" <> _} = Role.parse(" , ")
    assert {:error, "unknown role \"colector\"" <> _} = Role.parse("colector")
    assert {:error, _} = Role.parse("collector,worker")
  end

  test "a collector node never starts the site, and a web node never collects" do
    names = fn roles -> roles |> KickTracker.Application.children() |> Enum.map(&child_name/1) end

    assert KickTrackerWeb.Endpoint in names.([:web])
    refute KickTrackerWeb.Endpoint in names.([:collector])
    assert KickTrackerWeb.Endpoint in names.([:collector, :web])

    # Collection (the journal, the leader election and, while leading,
    # the collection tree) runs only on a collector.
    assert KickTracker.Collector.Supervisor in names.([:collector])
    refute KickTracker.Collector.Supervisor in names.([:web])

    without_collection =
      [:collector] |> KickTracker.Application.children(collect: false) |> Enum.map(&child_name/1)

    refute KickTracker.Collector.Supervisor in without_collection

    # A web node has its own app token (admin lookups, subscriptions); a
    # node that also collects shares the collector's.
    assert KickTracker.Kick.Token in names.([:web])
    assert Enum.count(names.([:collector, :web]), &(&1 == KickTracker.Kick.Token)) == 1

    # Both roles share the database and PubSub, the link from collector to site.
    for roles <- [[:collector], [:web]] do
      assert KickTracker.Repo in names.(roles)
      assert Phoenix.PubSub in names.(roles)
    end
  end

  test "the running test node was started with both roles" do
    assert Role.current() == [:collector, :web]
    assert Role.runs?(:web) and Role.runs?(:collector)
  end

  defp child_name({module, _opts}), do: module
  defp child_name(module) when is_atom(module), do: module

  test "a shadow collector polls and chats, but takes no webhooks and runs only its own jobs" do
    previous = Application.get_env(:kick_tracker, :collector, [])
    on_exit(fn -> Application.put_env(:kick_tracker, :collector, previous) end)

    ids = fn ->
      {:ok, {_, specs}} = KickTracker.Collector.Collection.init([])
      Enum.map(specs, & &1.id)
    end

    assert KickTracker.Events.Consumer in ids.()

    Application.put_env(:kick_tracker, :collector, Keyword.put(previous, :mode, :shadow))
    refute KickTracker.Events.Consumer in ids.()

    oban =
      [:collector]
      |> KickTracker.Application.children()
      |> Enum.find_value(fn
        {Oban, config} -> config
        _ -> nil
      end)

    crontab =
      get_in(oban, [:plugins])
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, o} -> o[:crontab]
        _ -> nil
      end)

    workers = Enum.map(crontab, &elem(&1, 1)) |> Enum.uniq()
    assert workers == [KickTracker.Workers.ShadowSync]
  end
end
