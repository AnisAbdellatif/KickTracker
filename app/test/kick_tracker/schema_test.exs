defmodule KickTracker.SchemaTest do
  @moduledoc """
  The database's own guarantees: the constraints that keep collected data
  honest even if application code gets something wrong (AGENTS.md §7).
  """

  # Not async: tests writing hypertables create chunks inside their
  # sandbox transactions, and concurrent chunk creation deadlocks.
  use KickTracker.DataCase, async: false

  alias KickTracker.Repo

  defp query!(sql, params \\ []), do: Repo.query!(sql, params)

  defp fails(sql, params \\ []) do
    assert {:error, %Postgrex.Error{postgres: %{code: code}}} = Repo.query(sql, params)
    code
  end

  defp channel!(user_id, slug, active \\ true) do
    %{rows: [[id]]} =
      query!(
        "INSERT INTO channels (kick_user_id, slug, active, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now()) RETURNING id",
        [user_id, slug, active]
      )

    id
  end

  defp stream!(channel_id, started_at) do
    %{rows: [[id]]} =
      query!("INSERT INTO streams (channel_id, started_at) VALUES ($1, $2) RETURNING id", [
        channel_id,
        started_at
      ])

    id
  end

  describe "channels" do
    test "a Kick user is tracked once" do
      channel!(1_234_567, "somestreamer")

      assert fails(
               "INSERT INTO channels (kick_user_id, slug, inserted_at, updated_at) VALUES (1234567, 'renamed', now(), now())"
             ) == :unique_violation
    end

    test "two active channels can't share a slug in any case; an inactive one doesn't block it" do
      channel!(1, "somestreamer")

      assert fails(
               "INSERT INTO channels (kick_user_id, slug, inserted_at, updated_at) VALUES (2, 'SomeStreamer', now(), now())"
             ) == :unique_violation

      channel!(3, "oldname", false)
      assert channel!(4, "OldName")
    end

    test "defaults: UTC timezone, tracked from now, active" do
      id = channel!(5, "somestreamer")

      %{rows: [[tz, active, recent]]} =
        query!(
          "SELECT timezone, active, tracked_since > now() - interval '1 minute' FROM channels WHERE id = $1",
          [id]
        )

      assert {tz, active, recent} == {"Etc/UTC", true, true}
    end
  end

  describe "streams" do
    setup do: %{channel: channel!(10, "somestreamer")}

    test "one stream per channel and start time: the identity Kick gives us", %{channel: c} do
      stream!(c, ~U[2026-01-05 20:00:00Z])

      assert fails("INSERT INTO streams (channel_id, started_at) VALUES ($1, $2)", [
               c,
               ~U[2026-01-05 20:00:00Z]
             ]) == :unique_violation

      assert stream!(c, ~U[2026-01-06 20:00:00Z])
    end

    test "an end can't come before the start, and always says how it was learnt", %{channel: c} do
      id = stream!(c, ~U[2026-01-05 20:00:00Z])

      assert fails(
               "UPDATE streams SET ended_at = '2026-01-05 19:00:00Z', end_source = 'event' WHERE id = $1",
               [id]
             ) == :check_violation

      assert fails("UPDATE streams SET ended_at = '2026-01-05 23:00:00Z' WHERE id = $1", [id]) ==
               :check_violation

      assert fails(
               "UPDATE streams SET ended_at = '2026-01-05 23:00:00Z', end_source = 'guess' WHERE id = $1",
               [id]
             ) == :check_violation

      query!(
        "UPDATE streams SET ended_at = '2026-01-05 23:00:00Z', end_source = 'poll' WHERE id = $1",
        [id]
      )
    end

    test "a channel with streams can't be deleted out from under them", %{channel: c} do
      stream!(c, ~U[2026-01-05 20:00:00Z])
      assert fails("DELETE FROM channels WHERE id = $1", [c]) == :restrict_violation
    end
  end

  describe "webhook_events" do
    @insert """
    INSERT INTO webhook_events
      (message_id, subscription_id, event_type, event_version, sent_at, occurred_at, signature, body, received_at, receiver)
    VALUES ($1, 'sub', 'channel.followed', '1', '2026-09-24T18:02:11Z', '2026-09-24T18:02:11Z', 'sig', $2, now(), 'test/1')
    """

    test "a repeated delivery is refused, and ON CONFLICT DO NOTHING makes it a no-op" do
      query!(@insert, ["01JH6X0T5B6Z6W9JQ3E4V8N2QK", "{}"])
      assert fails(@insert, ["01JH6X0T5B6Z6W9JQ3E4V8N2QK", "{}"]) == :unique_violation

      %{num_rows: 0} =
        query!(@insert <> " ON CONFLICT (message_id) DO NOTHING", [
          "01JH6X0T5B6Z6W9JQ3E4V8N2QK",
          "{}"
        ])
    end

    test "the body comes back byte for byte, which the signature depends on" do
      # Odd spacing, key order and a non-UTF-8 byte: jsonb would change all three.
      body = ~s({"z": 1,  "a":[ 2 ]}\n) <> <<0xFF>>
      query!(@insert, ["m1", body])

      assert %{rows: [[^body]]} =
               query!("SELECT body FROM webhook_events WHERE message_id = 'm1'")
    end

    test "new events are unprocessed until marked" do
      query!(@insert, ["m2", "{}"])

      assert %{rows: [[1]]} =
               query!("SELECT count(*) FROM webhook_events WHERE processed_at IS NULL")
    end
  end

  describe "viewer_samples" do
    setup do
      c = channel!(20, "somestreamer")
      %{channel: c, stream: stream!(c, ~U[2026-01-05 20:00:00Z])}
    end

    @insert "INSERT INTO viewer_samples (channel_id, observed_at, stream_id, viewers, category_id) VALUES ($1, $2, $3, $4, 15)"

    test "one reading per channel and moment, never negative", %{channel: c, stream: s} do
      query!(@insert, [c, ~U[2026-01-05 20:01:00Z], s, 500])
      assert fails(@insert, [c, ~U[2026-01-05 20:01:00Z], s, 600]) == :unique_violation
      assert fails(@insert, [c, ~U[2026-01-05 20:02:00Z], s, -1]) == :check_violation
    end

    test "a reading must belong to a real stream", %{channel: c} do
      assert fails(@insert, [c, ~U[2026-01-05 20:01:00Z], -1, 500]) == :foreign_key_violation
    end

    test "it's a hypertable, compressed after a week, grouped by channel" do
      assert %{rows: [["viewer_samples", true]]} =
               query!(
                 "SELECT hypertable_name, compression_enabled FROM timescaledb_information.hypertables WHERE hypertable_name = 'viewer_samples'"
               )

      assert %{rows: [["channel_id"]]} =
               query!(
                 "SELECT attname FROM timescaledb_information.compression_settings WHERE hypertable_name = 'viewer_samples' AND segmentby_column_index IS NOT NULL"
               )

      assert %{rows: [[%{"compress_after" => compress_after}]]} =
               query!(
                 "SELECT config FROM timescaledb_information.jobs WHERE hypertable_name = 'viewer_samples'"
               )

      assert compress_after =~ "7 days"
    end
  end

  describe "coverage" do
    test "known sources only, and an end can't precede its start" do
      assert fails("INSERT INTO coverage (source, from_at, ok) VALUES ('guesswork', now(), true)") ==
               :check_violation

      assert fails(
               "INSERT INTO coverage (source, from_at, to_at, ok) VALUES ('api', now(), now() - interval '1 hour', false)"
             ) == :check_violation

      query!("INSERT INTO coverage (source, from_at, ok) VALUES ('chat', now(), false)")
    end
  end
end
