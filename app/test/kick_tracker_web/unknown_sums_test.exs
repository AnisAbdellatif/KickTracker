defmodule KickTrackerWeb.UnknownSumsTest do
  use ExUnit.Case, async: true

  doctest KickTrackerWeb.SiteComponents, only: [known_sum: 1]

  alias KickTrackerWeb.HomeLive

  test "the total watching is unknown while any live channel has no current reading" do
    assert HomeLive.total_watching([%{viewers: 100}, %{viewers: 20}]) == 120
    # Before: the channel without a reading counted as 0, so this showed 100.
    assert HomeLive.total_watching([%{viewers: 100}, %{viewers: nil}]) == nil
    assert HomeLive.total_watching([]) == 0
  end
end
