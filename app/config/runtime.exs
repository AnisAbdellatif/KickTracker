import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kick_tracker start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kick_tracker, KickTrackerWeb.Endpoint, server: true
end

# 4100, not Phoenix's usual 4000, which other local projects tend to use.
config :kick_tracker, KickTrackerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4100"))]

# Which parts of the app this node runs (project.md §10): `collector`,
# `web`, or both (`collector,web`). Production must say; development and
# tests run both.
config :kick_tracker,
       :role,
       System.get_env("ROLE") ||
         if(config_env() == :prod,
           do: raise("ROLE is not set: use collector, web, or collector,web"),
           else: "collector,web"
         )

# Where Kick is. Every Kick URL and key comes from here (AGENTS.md §6), so
# the same code talks to the real Kick or to the fake one (`cd sim && mix
# sim`, which listens on 4050). Development and tests default to the fake
# one; production has no defaults and refuses to start without them.
sim = "http://127.0.0.1:4050"

kick_defaults =
  if config_env() in [:dev, :test] do
    %{
      "KICK_API_URL" => sim,
      "KICK_ID_URL" => sim,
      "KICK_V2_URL" => sim <> "/api/v2",
      "PUSHER_URL" =>
        "ws://127.0.0.1:4050/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false",
      "KICK_CLIENT_ID" => "dev-client",
      "KICK_CLIENT_SECRET" => "dev-secret",
      # The consume-only user from deploy/rabbitmq (local development only).
      "AMQP_URL" => "amqp://app:app-dev@127.0.0.1:55672"
    }
  else
    %{}
  end

setting = fn name ->
  System.get_env(name) || Map.get(kick_defaults, name) ||
    raise "#{name} is not set (see project.md §9 and AGENTS.md §6)"
end

config :kick_tracker, :kick,
  api_url: setting.("KICK_API_URL"),
  id_url: setting.("KICK_ID_URL"),
  v2_url: setting.("KICK_V2_URL"),
  pusher_url: setting.("PUSHER_URL"),
  client_id: setting.("KICK_CLIENT_ID"),
  client_secret: setting.("KICK_CLIENT_SECRET"),
  # Optional: fetched from the API when unset.
  public_key: System.get_env("KICK_PUBLIC_KEY")

config :kick_tracker, :amqp_url, setting.("AMQP_URL")

# The public name (never Kick's, project.md §18.3).
config :kick_tracker, :site_name, System.get_env("SITE_NAME", "Stream Tracker")

# Where alerts go (project.md §18.2); all optional.
config :kick_tracker, :alerts,
  webhook_url: System.get_env("ALERT_WEBHOOK_URL"),
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  telegram_chat_id: System.get_env("TELEGRAM_CHAT_ID"),
  heartbeat_url: System.get_env("HEARTBEAT_URL")

# Where privacy and removal requests go (project.md §18.3).
config :kick_tracker, :contact_email, System.get_env("CONTACT_EMAIL")

# Sent to Kick with every request (§18.3); built from the site name, host and
# contact address when unset.
config :kick_tracker, :kick_user_agent, System.get_env("KICK_USER_AGENT")
config :kick_tracker, :amqp_queue, System.get_env("AMQP_QUEUE", "kick_tracker.events")

# RabbitMQ's management API, for queue depths on the health page: a
# read-only monitoring user, e.g. http://monitor:<password>@rabbitmq:15672.
# Optional.
config :kick_tracker,
       :rabbitmq_management_url,
       System.get_env("RABBITMQ_MANAGEMENT_URL") ||
         if(config_env() == :dev, do: "http://monitor:monitor-dev@127.0.0.1:15673")

config :kick_tracker, :rabbitmq_vhost, System.get_env("RABBITMQ_VHOST", "/")

# The dead-letter queue, for the admin (inspect, replay, discard): the `ops`
# user, read on the dead-letter queue and write on the exchange. Optional.
dead_letters_default =
  case config_env() do
    :dev -> "amqp://ops:ops-dev@127.0.0.1:55672"
    :test -> "amqp://ops:ops-dev@127.0.0.1:55672/test"
    _ -> nil
  end

config :kick_tracker,
       :dead_letters_amqp_url,
       System.get_env("DEAD_LETTERS_AMQP_URL") || dead_letters_default

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :kick_tracker, KickTrackerWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/kick_tracker_web/router\.ex$"E,
        ~r"lib/kick_tracker_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :kick_tracker, KickTracker.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kick_tracker, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kick_tracker, KickTrackerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # IPv4 by default: containers often have no IPv6, where binding ::
      # fails; LISTEN_IPV6=true listens on both.
      ip:
        if(System.get_env("LISTEN_IPV6") in ~w(true 1),
          do: {0, 0, 0, 0, 0, 0, 0, 0},
          else: {0, 0, 0, 0}
        )
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kick_tracker, KickTrackerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kick_tracker, KickTrackerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :kick_tracker, KickTracker.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
