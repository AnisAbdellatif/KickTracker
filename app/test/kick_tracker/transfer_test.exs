defmodule KickTracker.TransferTest do
  @moduledoc """
  Export and import: a round trip rebuilds the same facts on an empty
  instance, a second import adds nothing, rows already here win, and
  removal requests survive in both directions.
  """

  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Events, Privacy, Removals, Transfer}
  alias KickTracker.Events.Envelope
  alias KickTracker.TestKick
  alias KickTracker.Transfer.{Export, Import}

  @person 424_242

  setup do
    dir = Path.join(System.tmp_dir!(), "transfer_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "the manifest" do
    test "accepts this version's exports and refuses the rest" do
      m =
        Transfer.manifest(%{
          exported_at: ~U[2026-09-01 00:00:00Z],
          site_name: "Stream Tracker",
          schema_version: 1,
          scope: :data,
          from: nil,
          to: nil,
          channels: [%{kick_user_id: 1, slug: "somestreamer"}],
          removed_channels: [],
          rows: %{"channels" => 1}
        })
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, %{"exported_at" => ~U[2026-09-01 00:00:00Z]}} =
               Transfer.validate(m, ["manifest.json", "channels.csv"])

      assert {:error, "unexpected files" <> _} =
               Transfer.validate(m, ["manifest.json", "../evil.csv"])

      assert {:error, "made by a newer version" <> _} =
               Transfer.validate(%{m | "version" => 99}, [])

      assert {:error, "not an export" <> _} = Transfer.validate(%{"format" => "other"}, [])
    end
  end

  describe "a round trip into an empty instance" do
    test "brings back the same facts, and a second import adds nothing", %{dir: dir} do
      c = history!()
      zip = export!(dir, [c.id])
      before = facts()

      wipe!()
      assert facts().streams == []

      assert {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert_same_facts(before)
      assert [_] = summary["new_channels"]
      assert summary["tables"]["viewer_samples"] == %{"in_file" => 3, "added" => 3}
      assert summary["from"] && summary["to"]

      {:ok, again} = Import.run(zip, Path.join(dir, "in"))
      assert again["tables"] |> Map.values() |> Enum.map(& &1["added"]) |> Enum.sum() == 0
      assert_same_facts(before)
    end

    test "open coverage is closed at the export's time", %{dir: dir} do
      c = channel!()

      Repo.insert_all("coverage", [
        %{channel_id: c.id, source: "api", from_at: ago(3600), ok: true}
      ])

      zip = export!(dir, [c.id])
      wipe!()

      {:ok, _} = Import.run(zip, Path.join(dir, "in"))
      assert [%{to_at: %DateTime{}}] = rows("coverage", ["from_at"])
    end
  end

  describe "merging" do
    test "rows already here win; missing ones are added", %{dir: dir} do
      c = history!()
      zip = export!(dir, [c.id])

      # Here: the same stream with one sample differing, and one missing.
      [s] = rows("streams", ["id"])
      [first, _second, third] = rows("viewer_samples", ["observed_at"])
      Repo.query!("DELETE FROM viewer_samples WHERE observed_at = $1", [third.observed_at])

      Repo.query!("UPDATE viewer_samples SET viewers = 1 WHERE observed_at = $1", [
        first.observed_at
      ])

      {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert summary["new_channels"] == []
      assert summary["tables"]["viewer_samples"]["added"] == 1
      assert [%{viewers: 1}, _, %{viewers: v}] = rows("viewer_samples", ["observed_at"])
      assert v == third.viewers
      assert [%{id: id}] = rows("streams", ["id"])
      assert id == s.id
    end

    test "the channel list alone creates the channels with their settings", %{dir: dir} do
      c = channel!(chatroom_id: 77)

      Repo.query!("UPDATE channels SET timezone = 'Africa/Tunis', public = false WHERE id = $1", [
        c.id
      ])

      history!(c)
      zip = export!(dir, [c.id], :channels)
      wipe!()

      {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert summary["tables"]["streams"] == %{"in_file" => 0, "added" => 0}

      assert [%{kick_user_id: kid, timezone: "Africa/Tunis", public: false, chatroom_id: 77}] =
               rows("channels", ["id"])

      assert kid == c.kick_user_id
      assert rows("streams", ["id"]) == []
    end

    test "with history a channel keeps when it was first tracked; the list alone doesn't claim it",
         %{dir: dir} do
      c = history!()
      Repo.query!("UPDATE channels SET tracked_since = $1 WHERE id = $2", [ago(3 * 86_400), c.id])
      [%{tracked_since: first}] = rows("channels", ["id"])
      list = export!(dir, [c.id], :channels)
      data = export!(dir, [c.id])

      # Before: the list alone set the other instance's date, so the two
      # days since read as a gap here. After: tracked from the import.
      wipe!()
      {:ok, _} = Import.run(list, Path.join(dir, "in"))
      [%{tracked_since: since}] = rows("channels", ["id"])
      assert DateTime.diff(DateTime.utc_now(), since) < 60

      # The list again, with an older date, leaves it alone; history moves it back.
      {:ok, _} = Import.run(list, Path.join(dir, "in"))
      assert [%{tracked_since: ^since}] = rows("channels", ["id"])
      {:ok, _} = Import.run(data, Path.join(dir, "in"))
      assert [%{tracked_since: ^first}] = rows("channels", ["id"])

      # Into an empty instance, history brings its date as it was.
      wipe!()
      {:ok, _} = Import.run(data, Path.join(dir, "in"))
      assert [%{tracked_since: ^first}] = rows("channels", ["id"])
    end
  end

  describe "removal requests" do
    test "a user removed here isn't brought back", %{dir: dir} do
      c = history!()
      zip = export!(dir, [c.id])
      wipe!()
      Privacy.delete(@person)

      {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert summary["removed_users_reapplied"] == 1

      assert Privacy.find(@person)
             |> Map.take([:username, :chat_streams, :chat_minutes, :follows]) ==
               %{username: nil, chat_streams: 0, chat_minutes: 0, follows: 0}

      # Still counted.
      assert [%{user_id: nil}] = rows("follows", ["message_id"])
    end

    test "a channel removed here isn't brought back", %{dir: dir} do
      c = history!()
      zip = export!(dir, [c.id])
      wipe!()
      Removals.record(:channel, c.kick_user_id)

      {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert summary["new_channels"] == []
      assert rows("channels", ["id"]) == []
      assert rows("webhook_events", ["message_id"]) == []
    end

    test "a removal made there travels, and names the channel to delete here", %{dir: dir} do
      here = channel!()
      Removals.record(:channel, here.kick_user_id)
      other = channel!()
      zip = export!(dir, [other.id], :channels)

      {:ok, manifest, _} = Import.read_manifest(zip)
      assert here.kick_user_id in manifest["removed_channels"]

      Repo.query!("DELETE FROM removals")
      {:ok, summary} = Import.run(zip, Path.join(dir, "in"))
      assert summary["delete_channels"] == [here.id]
    end

    test "adding a removed channel again by hand lifts its removal" do
      Removals.record(:channel, 5)
      Removals.clear_channel(5)
      assert rows("removals", ["kick_user_id"]) == []
    end
  end

  test "a file with columns this version doesn't know changes nothing", %{dir: dir} do
    c = history!()
    zip = export!(dir, [c.id])
    work = Path.join(dir, "edit")
    {:ok, files} = :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(work))
    csv = Path.join(work, "streams.csv")
    [header | rest] = File.read!(csv) |> String.split("\n")
    File.write!(csv, Enum.join([header <> ",mystery" | rest], "\n"))
    edited = Path.join(dir, "edited.zip")

    {:ok, _} =
      :zip.create(
        String.to_charlist(edited),
        Enum.map(files, &(&1 |> Path.relative_to(work) |> String.to_charlist())),
        cwd: String.to_charlist(work)
      )

    wipe!()

    assert {:error, "streams.csv has columns this version doesn't know: mystery"} =
             Import.run(edited, Path.join(dir, "in"))

    assert rows("channels", ["id"]) == []
  end

  # A channel with a stream, samples, a title change, chat, a follow and a
  # gift by @person (through real events), coverage, a group and an annotation.
  defp history!(c \\ nil) do
    c = c || channel!()
    at = ago(2 * 3600) |> DateTime.truncate(:second) |> Map.put(:second, 0)
    s = stream!(c, at, DateTime.add(at, 3600))
    samples!(c, s, for(i <- 0..2, do: {DateTime.add(at, i * 60), 100 + i}))
    b = TestKick.user(c.kick_user_id, "somestreamer")

    envelopes =
      for {type, body} <- [
            {"channel.followed",
             %{"broadcaster" => b, "follower" => TestKick.user(@person, "someone")}},
            {"channel.subscription.gifts",
             %{
               "broadcaster" => b,
               "gifter" => TestKick.user(@person, "someone"),
               "giftees" => [TestKick.user(8, "x")],
               "created_at" => DateTime.to_iso8601(DateTime.add(at, 600))
             }}
          ] do
        {:ok, e} = TestKick.message(type, body) |> Envelope.decode()
        e
      end

    {:ok, _} = Events.ingest(envelopes)

    Repo.insert_all("stream_changes", [
      %{
        stream_id: s,
        occurred_at: DateTime.add(at, 120),
        field: "title",
        new_value: "a title",
        source: "event"
      }
    ])

    minute = DateTime.add(at, 60)

    Repo.insert_all("chat_minutes", [
      %{channel_id: c.id, minute: minute, stream_id: s, messages: 3, chatters: 1}
    ])

    Repo.insert_all("chat_minute_users", [
      %{channel_id: c.id, minute: minute, user_id: @person, messages: 3}
    ])

    Repo.insert_all("chat_stream_users", [
      %{stream_id: s, user_id: @person, messages: 3, first_at: minute, last_at: minute}
    ])

    covered!(c, "api", at, DateTime.add(at, 3600))
    {:ok, g} = KickTracker.Groups.create("Some group #{c.id}", true)
    KickTracker.Groups.set_members(g, [c.id])

    Repo.insert_all("annotations", [
      %{
        channel_id: c.id,
        from_at: at,
        text: "a note",
        public: false,
        inserted_at: at,
        updated_at: at
      }
    ])

    c
  end

  defp export!(dir, ids, scope \\ :data) do
    zip = Path.join(dir, "export-#{System.unique_integer([:positive])}.zip")

    {:ok, _} =
      Export.run(
        %{scope: scope, channel_ids: ids, from: nil, to: nil},
        zip,
        Path.join(dir, "out")
      )

    zip
  end

  defp assert_same_facts(before) do
    now = facts()
    for {table, rows} <- before, do: assert({table, now[table]} == {table, rows})
  end

  # The facts, without local ids.
  defp facts do
    q = fn sql -> Repo.query!(sql).rows end

    %{
      channels:
        q.("SELECT kick_user_id, slug, timezone, active, public FROM channels ORDER BY 1"),
      streams:
        q.(
          "SELECT c.kick_user_id, started_at, ended_at FROM streams s JOIN channels c ON c.id = s.channel_id ORDER BY 2"
        ),
      samples: q.("SELECT observed_at, viewers FROM viewer_samples ORDER BY 1"),
      changes: q.("SELECT occurred_at, field, new_value FROM stream_changes ORDER BY 1"),
      follows: q.("SELECT message_id, occurred_at, user_id FROM follows ORDER BY 1"),
      support: q.("SELECT message_id, kind, quantity, user_id FROM support_events ORDER BY 1"),
      users: q.("SELECT id, username FROM kick_users ORDER BY 1"),
      chat:
        q.(
          "SELECT minute, messages, chatters, stream_id IS NOT NULL FROM chat_minutes ORDER BY 1"
        ),
      chat_users: q.("SELECT minute, user_id, messages FROM chat_minute_users ORDER BY 1"),
      stream_users: q.("SELECT user_id, messages FROM chat_stream_users ORDER BY 1"),
      coverage: q.("SELECT source, from_at, to_at, ok FROM coverage ORDER BY 2"),
      events: q.("SELECT message_id, body FROM webhook_events ORDER BY 1"),
      groups:
        q.(
          "SELECT g.slug, c.kick_user_id FROM channel_group_members m JOIN channel_groups g ON g.id = m.group_id JOIN channels c ON c.id = m.channel_id ORDER BY 1"
        ),
      annotations: q.("SELECT from_at, text FROM annotations ORDER BY 1")
    }
  end

  # An empty instance: everything an export carries, and what's derived from it.
  defp wipe! do
    for t <- ~w(stream_stats hourly_stats viewer_flags) ++ Enum.reverse(Transfer.tables()),
        do: Repo.query!("DELETE FROM #{t}")
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)
end
