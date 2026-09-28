defmodule KickTracker.DateResubsByDeliveryMigrationTest do
  @moduledoc """
  Resubs stored with the subscription's start as their time are dated by
  their delivery, and the rollups of the hours they left and joined are
  queued.
  """

  use KickTracker.DataCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import KickTracker.Fixtures
  alias KickTracker.{Events, TestKick}
  alias KickTracker.Events.Envelope
  alias KickTracker.Workers.Reprocess

  @migration Path.expand(
               "../../priv/repo/migrations/20260928120001_date_resubs_by_delivery.exs",
               __DIR__
             )

  defp migrate do
    Code.put_compiler_option(:ignore_module_conflict, true)
    [{module, _}] = Code.compile_file(@migration)
    Code.put_compiler_option(:ignore_module_conflict, false)
    Enum.each(module.statements(), &Repo.query!/1)
  end

  defp ingest!(type, body, sent_at) do
    {:ok, e} = TestKick.message(type, body, sent_at: sent_at) |> Envelope.decode()
    {:ok, _} = Events.ingest([e])
    e
  end

  defp at(message_id) do
    %{rows: [[at]]} =
      Repo.query!("SELECT occurred_at FROM support_events WHERE message_id = $1", [message_id])

    at
  end

  test "a resub dated by its subscription's start moves to its delivery; the rollups follow" do
    c = channel!()
    b = TestKick.user(c.kick_user_id, "somestreamer")
    started = ~U[2024-11-24 18:00:00Z]

    resub =
      ingest!(
        "channel.subscription.renewal",
        %{
          "broadcaster" => b,
          "subscriber" => TestKick.user(42, "fan"),
          "duration" => 22,
          "created_at" => DateTime.to_iso8601(started),
          "expires_at" => "2026-10-24T18:00:05Z"
        },
        "2026-09-24T18:00:05Z"
      )

    sub =
      ingest!(
        "channel.subscription.new",
        %{
          "broadcaster" => b,
          "subscriber" => TestKick.user(43, "otherfan"),
          "duration" => 1,
          "created_at" => "2026-09-24T18:00:01Z",
          "expires_at" => "2026-10-24T18:00:01Z"
        },
        "2026-09-24T18:00:02Z"
      )

    # As the code before the fix stored it, and rolled it up.
    Repo.query!("UPDATE support_events SET occurred_at = $1 WHERE message_id = $2", [
      started,
      resub.message_id
    ])

    KickTracker.Rollups.hourly(started, started)
    KickTracker.Rollups.hourly(~U[2026-09-24 18:00:00Z], ~U[2026-09-24 18:00:00Z])
    assert [%{subs: 1}, %{subs: 1}] = rows("hourly_stats", ["hour"])
    sub_at = at(sub.message_id)

    migrate()

    assert DateTime.compare(at(resub.message_id), resub.occurred_at) == :eq
    assert at(sub.message_id) == sub_at

    jobs = all_enqueued(worker: Reprocess)

    assert jobs |> Enum.map(& &1.args) |> Enum.sort_by(& &1["from"]) == [
             %{
               "kind" => "rollups",
               "from" => "2024-11-24T18:00:00Z",
               "to" => "2024-11-24T18:59:59Z"
             },
             %{
               "kind" => "rollups",
               "from" => "2026-09-24T18:00:00Z",
               "to" => "2026-09-24T18:59:59Z"
             }
           ]

    for job <- jobs, do: assert(:ok = perform_job(Reprocess, job.args))

    # The stale hour is gone; the resub counts where it happened.
    assert [%{hour: hour, subs: 2}] = rows("hourly_stats", ["hour"])
    assert DateTime.compare(hour, ~U[2026-09-24 18:00:00Z]) == :eq

    # Twice changes nothing and queues nothing more.
    migrate()
    assert length(all_enqueued(worker: Reprocess)) == 2
  end
end
