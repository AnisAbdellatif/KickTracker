defmodule Sim.Channel.Timeline do
  @moduledoc """
  Which webhooks a channel owes between one moment and the next. Pure, so
  the rules can be tested without processes, clocks or a network.

  What it emits, in the order the real Kick sends them:

    * a stream starting: `livestream.status.updated` (live), then
      `livestream.metadata.updated`, the way the recordings showed;
    * a title or category change partway through: `livestream.metadata.updated`;
    * a stream ending: `livestream.status.updated` with `ended_at`;
    * whatever happened minute by minute: follows, subs, gifts and Kicks.

  Starting a channel does **not** announce a stream already running: Kick
  announces transitions, not the state of the world.
  """

  alias Sim.{Events, Payloads, Schedule, StreamState}
  alias Sim.Scenario.Channel

  # A long pause or a fast clock shouldn't produce an hour of events at
  # once; beyond this the skipped minutes are simply not announced, which
  # is what a tracker would see if Kick had been unreachable.
  @max_minutes_per_step 60

  @type state :: %{
          window: Schedule.window() | nil,
          segment: non_neg_integer() | nil,
          minute: integer()
        }
  @type emission :: {String.t(), map()}

  @doc "The state of a channel at `at`, announcing nothing."
  @spec start(Channel.t(), DateTime.t()) :: state()
  def start(%Channel{} = channel, at) do
    window = Schedule.stream_at(channel, at)

    %{
      window: window,
      segment: window && StreamState.at(channel, window, at).index,
      minute: (window && minute_of(window, at)) || -1
    }
  end

  @doc "What the channel owes between its last state and `now`, and its new state."
  @spec advance(Channel.t(), state(), DateTime.t()) :: {[emission()], state()}
  def advance(%Channel{} = channel, state, now) do
    window = Schedule.stream_at(channel, now)

    if same_window?(state.window, window) do
      within(channel, state, window, now)
    else
      ended =
        if state.window, do: [end_of(channel, Schedule.current(channel, state.window))], else: []

      started = if window, do: start_of(channel, window, now), else: []
      {ended ++ started, start(channel, now)}
    end
  end

  defp within(_channel, state, nil, _now), do: {[], state}

  defp within(channel, state, window, now) do
    minute = minute_of(window, now)
    from = max(state.minute + 1, minute - @max_minutes_per_step + 1)

    minute_events =
      for m <- from..minute//1,
          m >= 0,
          event <- minute_events(channel, window, m),
          do: event

    segment = StreamState.at(channel, window, now).index

    changed =
      if segment != state.segment,
        do: [{"livestream.metadata.updated", Payloads.metadata_updated(channel, window, now)}],
        else: []

    {changed ++ minute_events, %{window: window, segment: segment, minute: minute}}
  end

  defp start_of(channel, window, now) do
    [
      {"livestream.status.updated", Payloads.status_updated(channel, window, now, true)},
      {"livestream.metadata.updated", Payloads.metadata_updated(channel, window, now)}
    ]
  end

  # The end event carries when the stream actually ended, not when we
  # noticed, which is how the recorded one looked.
  defp end_of(channel, window) do
    {"livestream.status.updated", Payloads.status_updated(channel, window, window.ends_at, false)}
  end

  defp minute_events(channel, window, minute) do
    at = DateTime.add(window.started_at, minute * 60, :second)
    viewers = Payloads.viewers(channel, window, at)

    channel
    |> Events.for_minute(viewers, minute)
    |> Enum.map(&to_emission(&1, channel, at))
  end

  defp to_emission({:follow, user_id}, channel, _at),
    do: {"channel.followed", Payloads.followed(channel, user_id)}

  defp to_emission({:sub, user_id, months}, channel, at),
    do: {"channel.subscription.new", Payloads.subscription(channel, user_id, months, at)}

  defp to_emission({:resub, user_id, months}, channel, at),
    do: {"channel.subscription.renewal", Payloads.subscription(channel, user_id, months, at)}

  defp to_emission({:gift, gifter, giftees}, channel, at),
    do: {"channel.subscription.gifts", Payloads.subscription_gifts(channel, gifter, giftees, at)}

  defp to_emission({:kicks, user_id, amount}, channel, at),
    do: {"kicks.gifted", Payloads.kicks_gifted(channel, user_id, amount, at)}

  defp to_emission({:ban, _moderator, user_id, permanent?}, channel, at),
    do: {"moderation.banned", Payloads.banned(channel, user_id, permanent?, at)}

  defp to_emission({:redemption, user_id, reward}, channel, at),
    do:
      {"channel.reward.redemption.updated",
       Payloads.reward_redemption(channel, user_id, reward, at)}

  defp same_window?(nil, nil), do: true
  defp same_window?(%{started_at: a}, %{started_at: b}), do: DateTime.compare(a, b) == :eq
  defp same_window?(_, _), do: false

  defp minute_of(window, at), do: at |> DateTime.diff(window.started_at, :second) |> div(60)
end
