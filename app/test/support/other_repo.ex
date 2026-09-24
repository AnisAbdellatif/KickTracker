defmodule KickTracker.OtherRepo do
  @moduledoc "The other side's database in tests (`KickTracker.OtherSide`), migrated with the app's migrations."
  use Ecto.Repo, otp_app: :kick_tracker, adapter: Ecto.Adapters.Postgres
end
