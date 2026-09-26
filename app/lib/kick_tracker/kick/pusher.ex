defmodule KickTracker.Kick.Pusher do
  @moduledoc """
  Frames of Kick's chat websocket (Pusher protocol 7), in and out
  (project.md §2.4). Pure.

  A frame's `data` is itself a JSON string. From a chat message only the
  sender, the message id and the time are read: **never the text**
  (AGENTS.md §7). Chat times end in `+00:00`, not `Z`.

  Hosts (Kick's raids) come as two events whose shape hasn't been seen
  yet: `StreamHostEvent` in the receiving channel's chatroom and
  `ChatMoveToSupportedChannelEvent` on the hosting channel's feed. They
  come out as `{:raw, name, channel, data}` with their data as sent, to be
  stored and parsed once real ones show their fields (project.md §16).
  Every other event this module doesn't know comes out as
  `{:other, name, channel}`, without its data, so the caller can notice
  new names without keeping what they carry.
  """

  @raw ["App\\Events\\StreamHostEvent", "App\\Events\\ChatMoveToSupportedChannelEvent"]

  @type frame ::
          {:connected, activity_timeout_s :: pos_integer()}
          | {:subscribed, String.t()}
          | :ping
          | :pong
          | {:chat,
             %{
               id: String.t() | nil,
               sender_id: integer(),
               username: String.t() | nil,
               at: DateTime.t()
             }}
          | {:error, integer() | nil, String.t() | nil}
          | {:raw, String.t(), String.t() | nil, term()}
          | {:other, String.t(), String.t() | nil}
          | :invalid

  @doc "Decodes one text frame from the server."
  @spec decode(String.t()) :: frame()
  def decode(text) do
    case Jason.decode(text) do
      {:ok, %{"event" => event} = frame} -> decode(event, frame)
      _ -> :invalid
    end
  end

  defp decode("pusher:connection_established", frame) do
    case data(frame) do
      %{"activity_timeout" => t} when is_integer(t) and t > 0 -> {:connected, t}
      _ -> {:connected, 120}
    end
  end

  defp decode("pusher_internal:subscription_succeeded", frame),
    do: {:subscribed, frame["channel"]}

  defp decode("pusher:ping", _frame), do: :ping
  defp decode("pusher:pong", _frame), do: :pong

  defp decode("pusher:error", frame) do
    case data(frame) do
      %{} = d -> {:error, d["code"], d["message"]}
      _ -> {:error, nil, nil}
    end
  end

  defp decode("App\\Events\\ChatMessageEvent", frame) do
    with %{"sender" => %{"id" => sender_id} = sender, "created_at" => created_at}
         when is_integer(sender_id) <- data(frame),
         {:ok, at, _} <- DateTime.from_iso8601(created_at) do
      {:chat,
       %{
         id: data(frame)["id"],
         sender_id: sender_id,
         username: sender["username"],
         at: KickTracker.Metrics.Sessionizer.norm(at)
       }}
    else
      _ -> :invalid
    end
  end

  defp decode(event, frame) when event in @raw,
    do: {:raw, event, frame["channel"], data(frame) || frame["data"]}

  defp decode(event, frame), do: {:other, event, frame["channel"]}

  @doc "The events kept as sent, for their channel's `channel_events`."
  @spec raw_events() :: [String.t()]
  def raw_events, do: @raw

  # `data` arrives as a JSON string (sometimes already an object).
  defp data(%{"data" => d}) when is_binary(d) do
    case Jason.decode(d) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp data(%{"data" => d}) when is_map(d), do: d
  defp data(_), do: nil

  @doc "A subscription to a public channel (Kick's chat needs no auth)."
  @spec subscribe(String.t()) :: String.t()
  def subscribe(channel),
    do:
      Jason.encode!(%{
        "event" => "pusher:subscribe",
        "data" => %{"auth" => "", "channel" => channel}
      })

  @spec pong() :: String.t()
  def pong, do: ~s({"event":"pusher:pong","data":{}})

  @spec ping() :: String.t()
  def ping, do: ~s({"event":"pusher:ping","data":{}})

  @doc "The Pusher channel carrying a chatroom's messages."
  @spec chatroom(integer()) :: String.t()
  def chatroom(chatroom_id), do: "chatrooms.#{chatroom_id}.v2"

  @doc "The per-channel Pusher channel (where raids and hosts may appear)."
  @spec channel(integer()) :: String.t()
  def channel(kick_channel_id), do: "channel.#{kick_channel_id}"
end
