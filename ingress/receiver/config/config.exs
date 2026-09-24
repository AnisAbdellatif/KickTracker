import Config

# Tests start the pieces they need themselves (see test/support).
config :receiver, start_children: config_env() != :test

import_config "#{config_env()}.exs"
