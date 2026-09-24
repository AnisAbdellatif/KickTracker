defmodule KickTracker.Repo do
  use Ecto.Repo,
    otp_app: :kick_tracker,
    adapter: Ecto.Adapters.Postgres
end
