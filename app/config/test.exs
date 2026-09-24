import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kick_tracker, KickTracker.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # deploy/compose.dev.yml publishes TimescaleDB here.
  port: 55432,
  database: "kick_tracker_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kick_tracker, KickTrackerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/IY2tmNvOHo3ZPfEq4djjij3Vly1dhgFauiGijcYUMLnESWNBe5pJg4nOceqZKXs",
  server: false

# Tests start the collection processes they need themselves.
config :kick_tracker, :collect, false
config :kick_tracker, Oban, testing: :manual

# In test we don't send emails
config :kick_tracker, KickTracker.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Password hashing is deliberately slow; tests don't need it to be.
config :kick_tracker, :pbkdf2_iterations, 1_000

# The query cache would outlive each test's rolled-back database.
config :kick_tracker, :cache, false
