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
end
