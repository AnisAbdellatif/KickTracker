defmodule KickTracker.Events.Facts do
  @moduledoc """
  What a follow, sub, gift or Kicks event says, as rows (project.md §12.5).
  Pure.

  Returns the fact and the Kick users it names (id and username, for
  `kick_users`, the only place usernames are kept). Message text in any
  event is never read. An event whose body lacks what a fact needs gives
  `:none`: it stays in `webhook_events` and can be replayed once the
  parser knows better.

  Only `channel.followed` has been recorded from the real Kick; the sub,
  gift and Kicks shapes follow Kick's documentation, as the simulator's do
  (project.md §16).
  """

  alias KickTracker.Events.Envelope

  @type user :: %{id: integer(), username: String.t()}
  @type fact ::
          {:follow, map()}
          | {:support, map()}

  @kinds %{
    "channel.subscription.new" => "sub",
    "channel.subscription.renewal" => "resub",
    "channel.subscription.gifts" => "gift",
    "kicks.gifted" => "kicks"
  }

  @doc "Event types that become facts."
  def types, do: ["channel.followed" | Map.keys(@kinds)]

  @doc """
  The fact in an event, for the channel `channel_id`, and the users it
  names. `occurred_at` is the body's own time when it has one, else the
  delivery's timestamp (a follow carries none).
  """
  @spec parse(Envelope.t(), integer()) :: {fact(), [user()]} | :none
  def parse(%Envelope{} = e, channel_id) do
    case Envelope.payload(e) do
      {:ok, body} when is_map(body) -> parse(e.event_type, body, e, channel_id)
      _ -> :none
    end
  end

  defp parse("channel.followed", %{"follower" => follower}, e, channel_id) do
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

  defp parse(type, body, e, channel_id)
       when type in ["channel.subscription.new", "channel.subscription.renewal"] do
    with %{} = u <- user(body["subscriber"]),
         months when is_integer(months) and months > 0 <- body["duration"] do
      row =
        support(e, channel_id, body, @kinds[type], u.id, months, nil, %{
          "expires_at" => body["expires_at"]
        })

      {{:support, row}, [u]}
    else
      _ -> :none
    end
  end

  defp parse("channel.subscription.gifts", body, e, channel_id) do
    giftees = body["giftees"] |> List.wrap() |> Enum.map(&user/1) |> Enum.reject(&is_nil/1)
    gifter = user(body["gifter"])

    case giftees do
      [] ->
        :none

      giftees ->
        row =
          support(e, channel_id, body, "gift", gifter && gifter.id, length(giftees), nil, %{
            "giftee_ids" => Enum.map(giftees, & &1.id),
            "anonymous" => gifter == nil,
            "expires_at" => body["expires_at"]
          })

        {{:support, row}, Enum.reject([gifter | giftees], &is_nil/1)}
    end
  end

  defp parse("kicks.gifted", body, e, channel_id) do
    gift = body["gift"] || %{}
    sender = user(body["sender"])

    case gift["amount"] do
      amount when is_integer(amount) and amount > 0 ->
        # The gift's message is the sender's text: not kept.
        row =
          support(e, channel_id, body, "kicks", sender && sender.id, amount, gift["tier"], %{
            "gift_type" => gift["type"],
            "gift_name" => gift["name"]
          })

        {{:support, row}, List.wrap(sender)}

      _ ->
        :none
    end
  end

  defp parse(_type, _body, _e, _channel_id), do: :none

  defp support(e, channel_id, body, kind, user_id, quantity, tier, payload) do
    %{
      message_id: e.message_id,
      channel_id: channel_id,
      occurred_at: time(body["created_at"]) || e.occurred_at,
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
