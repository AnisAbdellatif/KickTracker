defmodule Receiver.Application do
  @moduledoc """
  The receiver: key, spool, publisher, forwarder, the peer check, then the
  HTTP server last, so it only accepts deliveries once it can store them.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:receiver, :start_children, true), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Receiver.Supervisor)
  end

  defp children do
    env = &Application.fetch_env!(:receiver, &1)

    [
      {Receiver.PublicKey, pem: env.(:kick_public_key), api_url: env.(:kick_api_url)},
      {Receiver.Spool, path: env.(:spool_path)},
      {Receiver.Publisher,
       url: env.(:amqp_url),
       exchange: env.(:exchange),
       confirm_timeout_ms: env.(:confirm_timeout_ms)},
      Receiver.Forwarder,
      {Receiver.Peer, url: env.(:peer_health_url)},
      {Bandit, plug: Receiver.Router, port: env.(:port), ip: env.(:listen_ip)}
    ]
  end
end
