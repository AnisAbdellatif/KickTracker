defmodule KickTracker.Repo.Migrations.HoursWatchedNullable do
  use Ecto.Migration

  # Hours watched is null when there are no viewer samples, like the average
  # and the peak: no reading is not zero viewers (AGENTS.md §7).
  def change do
    alter table(:hourly_stats) do
      modify :hours_watched, :float,
        null: true,
        default: nil,
        from: {:float, null: false, default: 0.0}
    end

    alter table(:stream_stats) do
      modify :hours_watched, :float, null: true, from: {:float, null: false}
    end
  end
end
