defmodule KickTracker.TestBroker do
  @moduledoc """
  The development broker's `test` vhost (deploy/rabbitmq): the real
  topology and users, without touching development data.
  """

  @host "127.0.0.1:55672"

  def app_url, do: "amqp://app:app-dev@#{@host}/test"
  def admin_url, do: "amqp://admin:admin-dev@#{@host}/test"

  @doc "Publishes a message to `kick.events` as the ingress would."
  def publish(payload, routing_key \\ "channel.followed") do
    with_channel(fn chan ->
      :ok = AMQP.Confirm.select(chan)
      :ok = AMQP.Basic.publish(chan, "kick.events", routing_key, payload, persistent: true)
      true = AMQP.Confirm.wait_for_confirms(chan, 5_000)
    end)
  end

  @doc "How many messages wait in a queue."
  def depth(queue) do
    with_channel(fn chan -> AMQP.Queue.message_count(chan, queue) end)
  end

  @doc "Empties the test vhost's queues."
  def purge do
    with_channel(fn chan ->
      for q <- ["kick_tracker.events", "kick_tracker.events.dead"], do: AMQP.Queue.purge(chan, q)
    end)
  end

  defp with_channel(fun) do
    {:ok, conn} = AMQP.Connection.open(admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)

    try do
      fun.(chan)
    after
      AMQP.Connection.close(conn)
    end
  end
end
