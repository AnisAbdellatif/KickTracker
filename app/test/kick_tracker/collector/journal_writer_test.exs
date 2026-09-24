defmodule KickTracker.Collector.JournalWriterTest do
  @moduledoc """
  The journal on disk and the writer that empties it into Postgres:
  nothing lost when the database is away, nothing applied twice, a bad
  write set aside without blocking the rest, a superseded collector's
  writes fenced off.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Collector.{Journal, Writer}

  setup do
    path =
      Path.join(System.tmp_dir!(), "journal_test_#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> for f <- Path.wildcard(path <> "*"), do: File.rm(f) end)
    journal = start_supervised!({Journal, path: path, name: :test_journal})
    %{path: path, journal: journal}
  end

  defp writer(opts \\ []) do
    start_supervised!(
      {Writer,
       [name: :test_writer, journal: :test_journal, lease: "test-lease", shutdown_drain_ms: 0] ++
         opts}
    )
  end

  defp sample(c, s, v),
    do: {:follower_sample, c.id, DateTime.add(~U[2026-09-01 12:00:00Z], s), v}

  defp followers, do: rows("follower_samples", ["observed_at"]) |> Enum.map(& &1.followers)

  test "writes survive on disk, in order, across a restart", %{path: path} do
    c = channel!()
    :ok = Journal.append_to(:test_journal, [sample(c, 0, 1), sample(c, 60, 2)], 7)
    id = Journal.id(:test_journal)
    stop_supervised!(Journal)

    start_supervised!({Journal, path: path, name: :test_journal}, id: :again)
    assert Journal.id(:test_journal) == id

    assert [
             {_, 7, %DateTime{}, {:follower_sample, _, _, 1}},
             {_, 7, _, {:follower_sample, _, _, 2}}
           ] =
             Journal.take(10, :test_journal)

    assert %{depth: 2, oldest_at: %DateTime{}, buried: 0} = Journal.stats(:test_journal)
  end

  test "the writer applies everything and empties the journal" do
    c = channel!()
    :ok = Journal.append_to(:test_journal, [sample(c, 0, 1), sample(c, 60, 2)], 0)
    writer()

    assert :ok = Writer.drain(:test_writer)
    assert followers() == [1, 2]
    assert %{depth: 0} = Journal.stats(:test_journal)
  end

  test "a database that is away is waited out; nothing is lost" do
    c = channel!()
    :ok = Journal.append_to(:test_journal, [sample(c, 0, 1)], 0)
    down = :counters.new(1, [])

    apply = fn op ->
      if :counters.get(down, 1) == 0,
        do: raise(DBConnection.ConnectionError, "connection refused"),
        else: KickTracker.Collector.Ops.apply!(op)
    end

    writer(apply: apply)
    assert {:error, %DBConnection.ConnectionError{}} = Writer.drain(:test_writer)
    assert followers() == []
    assert %{depth: 1} = Journal.stats(:test_journal)

    :counters.add(down, 1, 1)
    assert :ok = Writer.drain(:test_writer)
    assert followers() == [1]
  end

  test "nothing is applied twice: the mark in Postgres wins over the journal" do
    c = channel!()

    :ok =
      Journal.append_to(:test_journal, [sample(c, 0, 1), sample(c, 60, 2), sample(c, 120, 3)], 0)

    [{first, _, _, _}, {second, _, _, _} | _] = Journal.take(10, :test_journal)

    # As if a crash came after the commit of the first two, before the
    # journal forgot them.
    Repo.query!(
      "INSERT INTO collector_journal_marks (journal_id, last_op, updated_at) VALUES ($1, $2, now())",
      [Journal.id(:test_journal), second]
    )

    applied = :counters.new(1, [])

    writer(
      apply: fn op ->
        :counters.add(applied, 1, 1)
        KickTracker.Collector.Ops.apply!(op)
      end
    )

    assert :ok = Writer.drain(:test_writer)
    assert :counters.get(applied, 1) == 1
    assert followers() == [3]
    assert first < second
  end

  test "a write that can never apply is set aside; the others go through" do
    c = channel!()

    :ok =
      Journal.append_to(
        :test_journal,
        [
          sample(c, 0, 1),
          {:follower_sample, 999_999_999, ~U[2026-09-01 12:01:00Z], 5},
          sample(c, 120, 3)
        ],
        0
      )

    writer()
    assert :ok = Writer.drain(:test_writer)
    assert followers() == [1, 3]
    assert %{depth: 0, buried: 1} = Journal.stats(:test_journal)
  end

  test "writes a superseded collector made after the takeover are dropped" do
    c = channel!()
    takeover = DateTime.add(DateTime.utc_now(), -30)

    Repo.query!(
      "INSERT INTO collector_terms (name, epoch, holder, started_at) VALUES ('test-lease', 2, 'b', $1)",
      [takeover]
    )

    # Made by holder 1 after holder 2 started (the journal stamps now).
    :ok = Journal.append_to(:test_journal, [sample(c, 0, 1)], 1)
    # Made by holder 2.
    :ok = Journal.append_to(:test_journal, [sample(c, 60, 2)], 2)

    writer()
    assert :ok = Writer.drain(:test_writer)
    assert followers() == [2]
  end

  test "snapshots are kept by key", %{path: path} do
    GenServer.cast(:test_journal, {:put, {:channel_state, 1}, %{a: 1}})
    assert GenServer.call(:test_journal, {:get, {:channel_state, 1}}) == %{a: 1}
    stop_supervised!(Journal)
    start_supervised!({Journal, path: path, name: :test_journal}, id: :again)
    assert GenServer.call(:test_journal, {:get, {:channel_state, 1}}) == %{a: 1}
  end
end
