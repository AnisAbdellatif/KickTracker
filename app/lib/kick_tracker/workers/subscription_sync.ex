defmodule KickTracker.Workers.SubscriptionSync do
  @moduledoc """
  Makes Kick's webhook subscriptions match the tracked channels (project.md
  §10): subscribes active channels to every event type we use, removes
  subscriptions for channels no longer tracked and duplicates, and
  **restores subscriptions Kick cancelled** (it drops an app's
  subscription after failing to deliver for over a day).

  Where deliveries go is set once in the Kick app's settings (the ingress
  URL), not per subscription. Runs on every change to the tracked set and
  every 15 minutes.
  """

  use Oban.Worker,
    queue: :kick,
    max_attempts: 5,
    unique: [period: 60, states: [:available, :scheduled]]

  require Logger

  alias KickTracker.Channels
  alias KickTracker.Kick.API

  # What the tracker reads. Bans, redemptions and chat (read over Pusher
  # instead) aren't subscribed to.
  @events ~w(
    livestream.status.updated livestream.metadata.updated
    channel.followed
    channel.subscription.new channel.subscription.renewal channel.subscription.gifts
    kicks.gifted
  )

  @doc "The event types every tracked channel is subscribed to."
  def events, do: @events

  @doc "Queues a sync."
  def enqueue, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, existing} <- API.subscriptions() do
      {to_create, to_delete} = plan(Channels.list_active(), existing)

      created =
        for {user_id, events} <- to_create do
          case API.subscribe(user_id, events) do
            {:ok, _} ->
              length(events)

            error ->
              Logger.error("could not subscribe #{user_id}: #{inspect(error)}")
              0
          end
        end

      with :ok <- API.unsubscribe(to_delete) do
        Logger.info("subscriptions: #{Enum.sum(created)} created, #{length(to_delete)} removed")
        :ok
      end
    end
  end

  @doc """
  What to create (per broadcaster, the missing event types) and which
  subscription ids to delete, given the active channels and Kick's list.
  Pure.
  """
  @spec plan([map()], [map()]) :: {[{integer(), [String.t()]}], [String.t()]}
  def plan(channels, existing) do
    wanted = MapSet.new(for c <- channels, e <- @events, do: {c.kick_user_id, e})

    {keep, delete} =
      existing
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce({MapSet.new(), []}, fn sub, {seen, delete} ->
        key = {sub["broadcaster_user_id"], sub["event"]}

        if MapSet.member?(wanted, key) and not MapSet.member?(seen, key),
          do: {MapSet.put(seen, key), delete},
          else: {seen, [sub["id"] | delete]}
      end)

    create =
      wanted
      |> MapSet.difference(keep)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {user_id, events} -> {user_id, Enum.sort(events)} end)
      |> Enum.sort()

    {create, Enum.reverse(delete)}
  end

  # A stuck job gives its slot back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)
end
