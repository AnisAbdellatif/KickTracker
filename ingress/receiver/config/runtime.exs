import Config

# Everything the receiver needs, from the environment (AGENTS.md §6).
# Development defaults point at the fake Kick and the local broker; in
# production every value must be given.
dev? = config_env() in [:dev, :test]

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
  confirm_timeout_ms: String.to_integer(System.get_env("CONFIRM_TIMEOUT_MS", "5000"))
