defmodule KickTracker.Events.Facts do
  @moduledoc """
  What a follow, sub, gift or Kicks event says, as rows (project.md §12.5).
  Pure.

  The body is read by kicksdk (`Kicksdk.Webhooks.parse/2`, by the event
  type). Returns the fact and the Kick users it names (id and username, for
  `kick_users`, the only place usernames are kept). Message text in any
  event is never read. An event whose body lacks what a fact needs gives
  `:none`: the event is still stored in `webhook_events` and marked
  processed, so nothing automatic looks at it again (the `ProcessEvents`
  retry job only sees unprocessed events). Only an admin replay
  (`Workers.Reprocess`, kind `"replay"`) runs it through the parser again,
  once the parser knows better.

  Only `channel.followed` has been recorded from the real Kick; the sub,
  gift and Kicks shapes follow Kick's documentation, as the simulator's do
  (project.md §16), checked against the key names of production's stored
  bodies (KICK.md §4.1).
  """

  alias KickTracker.Events.Envelope

  @type user :: %{id: integer(), username: String.t()}
  @type fact ::
          {:follow, map()}
          | {:support, map()}

  @types ~w(channel.followed channel.subscription.new channel.subscription.renewal
    channel.subscription.gifts kicks.gifted)

  @doc "Event types that become facts."
  def types, do: @types

  @doc """
  The fact in an event, for the channel `channel_id`, and the users it
  names. `occurred_at` is the body's own time when it has one, else the
  delivery's timestamp (a follow carries none). A renewal is dated by the
  delivery too: its `created_at` is when the subscription first started,
  months or years before (KICK.md §4.1).
  """
  @spec parse(Envelope.t(), integer()) :: {fact(), [user()]} | :none
  def parse(%Envelope{} = e, channel_id) do
    # kicksdk reads the body by its type (`Kicksdk.Webhooks.parse/2`); one
    # that isn't UTF-8, or isn't the type's shape, is an error.
    case Kicksdk.Webhooks.parse(e.event_type, e.body) do
      {:ok, event} -> fact(event, e, channel_id)
      {:error, _} -> :none
    end
  end

  defp fact(%{"type" => "followed", "follower" => follower}, e, channel_id) do
    case user(follower) do
      nil ->
        :none

      u ->
        {{:follow,
          %{
            message_id: e.message_id,
            channel_id: channel_id,
            occurred_at: e.occurred_at,
            user_id: u.id
          }}, [u]}
    end
  end

  defp fact(%{"type" => "subscription"} = event, e, channel_id) do
    with %{} = u <- user(event["subscriber"]),
         months when is_integer(months) and months > 0 <- event["duration"] do
      kind = if event["renewal"], do: "resub", else: "sub"

      row =
        support(e, channel_id, event, kind, u.id, months, nil, %{
          "expires_at" => event["expires_at"]
        })

      row = if event["renewal"], do: %{row | occurred_at: e.occurred_at}, else: row
      {{:support, row}, [u]}
    else
      _ -> :none
    end
  end

  defp fact(%{"type" => "subscription_gifts"} = event, e, channel_id) do
    giftees = event["giftees"] |> List.wrap() |> Enum.map(&user/1) |> Enum.reject(&is_nil/1)
    gifter = user(event["gifter"])

    case giftees do
      [] ->
        :none

      giftees ->
        row =
          support(e, channel_id, event, "gift", gifter && gifter.id, length(giftees), nil, %{
            "giftee_ids" => Enum.map(giftees, & &1.id),
            "anonymous" => gifter == nil,
            "expires_at" => event["expires_at"]
          })

        {{:support, row}, Enum.reject([gifter | giftees], &is_nil/1)}
    end
  end

  defp fact(%{"type" => "kicks_gifted"} = event, e, channel_id) do
    sender = user(event["sender"])

    case event["amount"] do
      amount when is_integer(amount) and amount > 0 ->
        # The gift's message is the sender's text: not kept.
        row =
          support(e, channel_id, event, "kicks", sender && sender.id, amount, event["tier"], %{
            "gift_type" => event["kind"],
            "gift_name" => event["name"]
          })

        {{:support, row}, List.wrap(sender)}

      _ ->
        :none
    end
  end

  defp fact(_event, _e, _channel_id), do: :none

  defp support(e, channel_id, event, kind, user_id, quantity, tier, payload) do
    %{
      message_id: e.message_id,
      channel_id: channel_id,
      occurred_at: time(event["created_at"]) || e.occurred_at,
      kind: kind,
      user_id: user_id,
      quantity: quantity,
      tier: tier,
      payload: payload |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    }
  end

  # A named Kick user; anonymous gifters have no id.
  defp user(%{"user_id" => id, "username" => name}) when is_integer(id) and is_binary(name),
    do: %{id: id, username: name}

  defp user(_), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> KickTracker.Metrics.Sessionizer.norm(at)
      _ -> nil
    end
  end

  defp time(_), do: nil
end
