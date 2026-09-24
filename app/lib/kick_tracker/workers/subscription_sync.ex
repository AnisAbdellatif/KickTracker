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
  alias KickTracker.Stats.Coverage

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
      channels = Channels.list_active()
      {to_create, to_delete} = plan(channels, existing)

      results =
        for {user_id, events} <- to_create do
          case API.subscribe(user_id, events) do
            {:ok, _} ->
              {user_id, length(events)}

            error ->
              Logger.error("could not subscribe #{user_id}: #{inspect(error)}")
              {user_id, :failed}
          end
        end

      record_coverage(channels, results)
      created = for {_, n} <- results, is_integer(n), do: n

      with :ok <- API.unsubscribe(to_delete) do
        Logger.info("subscriptions: #{Enum.sum(created)} created, #{length(to_delete)} removed")
        :ok
      end
    end
  end

  # Ingress coverage (project.md §12.5): a channel whose subscriptions are
  # all in place at Kick is receiving its events until the next check
  # (Kick retries a delivery for about a day, so a receiver restart loses
  # nothing). One whose subscribing failed isn't. A failed check records
  # nothing: that time is a gap. Webhook counts (follows, subs, gifts,
  # Kicks) are 0 only where this says we were receiving.
  @check_gap_s 20 * 60

  defp record_coverage(channels, results) do
    failed = MapSet.new(for {user_id, :failed} <- results, do: user_id)
    {bad, good} = Enum.split_with(channels, &MapSet.member?(failed, &1.kick_user_id))
    now = DateTime.utc_now()

    if good != [],
      do: Coverage.mark(Enum.map(good, & &1.id), "ingress", true, now, @check_gap_s)

    if bad != [], do: Coverage.mark(Enum.map(bad, & &1.id), "ingress", false, now, @check_gap_s)
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
