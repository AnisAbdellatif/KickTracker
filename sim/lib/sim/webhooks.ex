defmodule Sim.Webhooks do
  @moduledoc """
  The fake Kick's webhook side: which events an app has subscribed to, and
  delivering them to the app's webhook URL, signed with the simulator's own
  key.

  Deliveries copy what the recordings showed: a ULID message id, the six
  `Kick-Event-*` headers, and a signature over
  `message_id.timestamp.raw body`. Anything that isn't a 2xx is retried,
  and the scenario's faults decide whether a delivery is dropped, doubled
  or delayed, so a tracker can be tested against the failures that are rare
  in real life.
  """

  use GenServer

  alias Sim.Kick.Signature
  alias Sim.{Payloads, Scenario, Server}

  @table __MODULE__.Subscriptions
  @retry_delays_ms [1_000, 5_000, 30_000]

  defmodule Subscription do
    @moduledoc false
    defstruct [:id, :broadcaster_user_id, :event, :version, :created_at]
  end

  # Every event type Kick documents (docs.kick.com/events/event-types).
  # `chat.message.sent` is served over Pusher instead, so the simulator
  # accepts a subscription to it but sends nothing.
  @event_types ~w(
    livestream.status.updated livestream.metadata.updated
    channel.followed
    channel.subscription.new channel.subscription.renewal channel.subscription.gifts
    kicks.gifted moderation.banned channel.reward.redemption.updated
    chat.message.sent
  )

  @doc "Every event type the fake Kick knows about."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{url: Keyword.get(opts, :webhook_url), sent: []}}
  end

  @doc "Where deliveries are sent. Nil means the simulator has nowhere to deliver."
  @spec webhook_url() :: String.t() | nil
  def webhook_url, do: GenServer.call(__MODULE__, :url)

  @spec put_webhook_url(String.t() | nil) :: :ok
  def put_webhook_url(url), do: GenServer.call(__MODULE__, {:put_url, url})

  @doc "Subscribes one channel to events, answering in Kick's shape."
  @spec subscribe(integer(), [map()]) :: [map()]
  def subscribe(broadcaster_user_id, events) do
    Enum.map(events, fn event ->
      name = event["name"]
      version = event["version"] || 1

      subscription = %Subscription{
        id: ulid(),
        broadcaster_user_id: broadcaster_user_id,
        event: name,
        version: version,
        created_at: DateTime.utc_now()
      }

      :ets.insert(@table, {subscription.id, subscription})
      %{"name" => name, "version" => version, "subscription_id" => subscription.id}
    end)
  end

  @doc "Every subscription, in the shape `GET /events/subscriptions` returns."
  @spec list() :: [map()]
  def list do
    for {_id, s} <- :ets.tab2list(@table) do
      %{
        "id" => s.id,
        "app_id" => "sim",
        "broadcaster_user_id" => s.broadcaster_user_id,
        "event" => s.event,
        "method" => "webhook",
        "version" => s.version,
        "created_at" => Payloads.iso(s.created_at),
        "updated_at" => Payloads.iso(s.created_at)
      }
    end
  end

  @spec unsubscribe([String.t()]) :: :ok
  def unsubscribe(ids) do
    Enum.each(ids, &:ets.delete(@table, &1))
  end

  @doc "The subscription for this channel and event, or nil."
  @spec subscription_for(integer(), String.t()) :: Subscription.t() | nil
  def subscription_for(broadcaster_user_id, event) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn {_id, s} ->
      if s.broadcaster_user_id == broadcaster_user_id and s.event == event, do: s
    end)
  end

  @doc """
  Delivers an event, if the app subscribed to it. Returns `:ignored` when
  there is no subscription or no URL, so a scenario can run with no
  listener at all.
  """
  @spec deliver(integer(), String.t(), map(), DateTime.t()) :: :ok | :ignored
  def deliver(broadcaster_user_id, event, body, at) do
    GenServer.call(__MODULE__, {:deliver, broadcaster_user_id, event, body, at})
  end

  @doc "Every delivery attempted so far, newest first. For tests and the control API."
  @spec sent() :: [map()]
  def sent, do: GenServer.call(__MODULE__, :sent)

  @impl true
  def handle_call(:url, _from, state), do: {:reply, state.url, state}
  def handle_call({:put_url, url}, _from, state), do: {:reply, :ok, %{state | url: url}}
  def handle_call(:sent, _from, state), do: {:reply, state.sent, state}

  def handle_call({:deliver, user_id, event, body, at}, _from, state) do
    subscription = subscription_for(user_id, event)

    cond do
      is_nil(state.url) or is_nil(subscription) ->
        {:reply, :ignored, state}

      drop?() ->
        {:reply, :ok, record(state, %{event: event, at: at, dropped: true})}

      true ->
        delivery = build(subscription, event, body, at)
        send(self(), {:attempt, delivery, 0})
        if duplicate?(), do: send(self(), {:attempt, delivery, 0})
        {:reply, :ok, record(state, %{event: event, at: at, message_id: delivery.message_id})}
    end
  end

  @impl true
  def handle_info({:attempt, delivery, attempt}, state) do
    case post(state.url, delivery) do
      :ok ->
        :ok

      :retry ->
        case Enum.at(@retry_delays_ms, attempt) do
          nil -> :ok
          delay -> Process.send_after(self(), {:attempt, delivery, attempt + 1}, delay)
        end
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build(subscription, event, body, at) do
    raw = Jason.encode!(body)
    message_id = ulid()
    timestamp = Payloads.iso(at)

    %{
      message_id: message_id,
      subscription_id: subscription.id,
      event: event,
      version: subscription.version,
      timestamp: timestamp,
      body: raw,
      signature: Signature.sign(Server.private_key(), message_id, timestamp, raw)
    }
  end

  defp post(url, delivery) do
    headers = [
      {"content-type", "application/json"},
      {"kick-event-message-id", delivery.message_id},
      {"kick-event-subscription-id", delivery.subscription_id},
      {"kick-event-signature", delivery.signature},
      {"kick-event-message-timestamp", delivery.timestamp},
      {"kick-event-type", delivery.event},
      {"kick-event-version", to_string(delivery.version)}
    ]

    case Req.post(
           url: url,
           headers: headers,
           body: delivery.body,
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> :retry
    end
  end

  defp record(state, entry), do: %{state | sent: Enum.take([entry | state.sent], 500)}

  defp drop?, do: chance(Scenario.fault(Server.scenario(), :drop_webhooks, 0))
  defp duplicate?, do: chance(Scenario.fault(Server.scenario(), :duplicate_webhooks, 0))

  defp chance(probability) when is_number(probability) and probability > 0,
    do: :rand.uniform() < probability

  defp chance(_), do: false

  # Kick's message and subscription ids are ULIDs: a millisecond timestamp
  # followed by randomness, in Crockford base32, so they sort by time.
  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  defp ulid do
    time = System.system_time(:millisecond)
    <<random::80>> = :crypto.strong_rand_bytes(10)
    encode(time, 10) <> encode(random, 16)
  end

  defp encode(number, length) do
    Enum.reduce((length - 1)..0//-1, [], fn position, acc ->
      [Enum.at(@crockford, number |> div(32 ** position) |> rem(32)) | acc]
    end)
    |> Enum.reverse()
    |> List.to_string()
  end
end
