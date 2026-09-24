defmodule KickTracker.ChannelsSlugTest do
  @moduledoc """
  Renames reported by Kick, including one that takes a slug another
  tracked channel still holds here: resolved, never raised.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Channels

  @at ~U[2026-09-01 12:00:00Z]

  defp slugs(c),
    do:
      Repo.query!(
        "SELECT slug, seen_to IS NULL FROM channel_slugs WHERE channel_id = $1 ORDER BY id",
        [c.id]
      ).rows

  test "a rename is followed and its history kept" do
    c = channel!(slug: "somestreamer")
    :ok = Channels.store_slug(c.id, "somestreamer", DateTime.add(@at, -60))
    :ok = Channels.store_slug(c.id, "renamedstreamer", @at)

    assert Channels.get!(c.id).slug == "renamedstreamer"
    assert slugs(c) == [["somestreamer", false], ["renamedstreamer", true]]
  end

  test "a slug taken over from another tracked channel moves; the stale holder gets a placeholder" do
    # `a` was renamed (or banned) and Kick's answer no longer lists it;
    # `b` now uses its old slug. Before, the unique index made this raise,
    # and the write could never apply.
    a = channel!(slug: "takenslug")
    b = channel!(slug: "otherslug")
    :ok = Channels.store_slug(a.id, "takenslug", DateTime.add(@at, -60))

    :ok = Channels.store_slug(b.id, "takenslug", @at)

    assert Channels.get!(b.id).slug == "takenslug"
    assert Channels.get!(a.id).slug == "takenslug~#{a.id}"
    # Its period under that slug is closed; its new slug starts one when Kick reports it.
    assert slugs(a) == [["takenslug", false]]

    :ok = Channels.store_slug(a.id, "itsnewslug", DateTime.add(@at, 300))
    assert Channels.get!(a.id).slug == "itsnewslug"
    assert slugs(a) == [["takenslug", false], ["itsnewslug", true]]
  end

  test "an inactive channel keeps its old slug without blocking anyone" do
    a = channel!(slug: "freedslug", active: false)
    b = channel!(slug: "someslug")
    :ok = Channels.store_slug(b.id, "freedslug", @at)
    assert Channels.get!(a.id).slug == "freedslug"
    assert Channels.get!(b.id).slug == "freedslug"
  end
end
