import Config

# Everything the receiver needs, from the environment (AGENTS.md §6).
# Development defaults point at the fake Kick and the local broker; in
# production every value must be given.
dev? = config_env() in [:dev, :test]

# A variable set to nothing (left for later in an env file) means "not
# set", as in the app.
for {name, ""} <- System.get_env(), do: System.delete_env(name)

setting = fn name, dev_default ->
  System.get_env(name) || (dev? && dev_default) ||
    raise "#{name} is not set (see ingress/receiver/README.md)"
end

config :receiver,
  port: String.to_integer(setting.("PORT", "4060")),
  # Loopback in development; in a container, every interface (Caddy reaches
  # it over the compose network). LISTEN_IP overrides.
  listen_ip:
    System.get_env("LISTEN_IP", if(dev?, do: "127.0.0.1", else: "0.0.0.0"))
    |> String.to_charlist()
    |> :inet.parse_address()
    |> elem(1),
  # Which receiver this is, written into every envelope for tracing.
  receiver_id: setting.("RECEIVER_ID", "dev/1"),
  # Where Kick's webhook signing key comes from: given directly, or fetched
  # from the API's /public/v1/public-key.
  kick_public_key: System.get_env("KICK_PUBLIC_KEY"),
  kick_api_url: setting.("KICK_API_URL", "http://127.0.0.1:4050"),
  # The publish-only user from deploy/rabbitmq (local development only).
  amqp_url: setting.("AMQP_URL", "amqp://receiver:receiver-dev@127.0.0.1:55672"),
  exchange: System.get_env("AMQP_EXCHANGE", "kick.events"),
  spool_path: setting.("SPOOL_PATH", "spool.sqlite3"),
  # How long to wait for RabbitMQ's confirm before spooling, in milliseconds.
  confirm_timeout_ms: String.to_integer(System.get_env("CONFIRM_TIMEOUT_MS", "5000")),
  # Refuse (400) deliveries whose signed timestamp is older than this, so a
  # captured delivery can't be replayed much later. Lenient on purpose: Kick
  # retries failed deliveries (for up to about a day). 0 turns it off.
  max_event_age_s:
    (case String.to_integer(System.get_env("MAX_EVENT_AGE_S", "259200")) do
       0 -> nil
       seconds -> seconds
     end),
  # After RabbitMQ has been unreachable this long, /health says 503 if the
  # peer receiver (PEER_HEALTH_URL, its /health) can publish, so the load
  # balancer sends deliveries there instead.
  broker_grace_s: String.to_integer(System.get_env("HEALTH_BROKER_GRACE_S", "30")),
  peer_health_url: System.get_env("PEER_HEALTH_URL"),
  # /health flags the spool (spool_over_limit) past this size; nothing is
  # refused for it.
  spool_warn_bytes: String.to_integer(System.get_env("SPOOL_WARN_BYTES", "1073741824"))
