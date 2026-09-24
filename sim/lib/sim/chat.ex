defmodule Sim.Chat do
  @moduledoc """
  The chat messages a simulated stream's audience sends between two
  moments. Pure and deterministic from the channel's seed, like the rest of
  the simulator: asking twice about the same interval gives the same
  messages, with the same ids.

  How many messages a minute, and from whom, comes from `Sim.Curve`, so
  chat rises and falls with the audience and the same people come back.
  Within a minute, messages land at scattered moments rather than in a
  burst. About one in twenty is a reply to an earlier message in the same
  minute, the way the recordings showed replies carrying the original
  message and its sender.
  """

  alias Sim.{Curve, Payloads, Schedule}
  alias Sim.Scenario.Channel

  @type message :: %{
          id: String.t(),
          at: DateTime.t(),
          sender_id: pos_integer(),
          content: String.t(),
          reply_to: %{id: String.t(), sender_id: pos_integer(), content: String.t()} | nil
        }

  @lines [
    "gg",
    "lol",
    "hello everyone",
    "no way",
    "that was close",
    "let's go",
    "first time here",
    "what did I miss",
    "this song is good",
    "W",
    "L",
    "[emote:37226:KEKW]",
    "[emote:39261:catJAM] [emote:39261:catJAM]",
    "hahaha [emote:37226:KEKW]",
    "how long is the stream today?"
  ]

  @doc """
  Every message sent strictly after `from` and at or before `to`, oldest
  first. Only minutes of the given stream count; outside it the chat is
  silent.
  """
  @spec between(Channel.t(), Schedule.window(), DateTime.t(), DateTime.t()) :: [message()]
  def between(%Channel{} = channel, window, from, to) do
    from = later(from, DateTime.add(window.started_at, -1, :millisecond))
    to = earlier(to, window.ends_at)

    if DateTime.compare(from, to) != :lt do
      []
    else
      first = minute_of(window, from)
      last = minute_of(window, to)

      for minute <- first..last//1,
          minute >= 0,
          message <- minute(channel, window, minute),
          DateTime.compare(message.at, from) == :gt,
          DateTime.compare(message.at, to) != :gt,
          do: message
    end
  end

  @doc "Every message of one minute of a stream, oldest first."
  @spec minute(Channel.t(), Schedule.window(), non_neg_integer()) :: [message()]
  def minute(%Channel{} = channel, window, minute) do
    start = DateTime.add(window.started_at, minute * 60, :second)
    viewers = Payloads.viewers(channel, window, start)
    count = Curve.messages_per_minute(channel, viewers, minute * 60)
    chatters = Curve.chatters(channel, count, minute * 60)

    if chatters == [] do
      []
    else
      stamp = DateTime.to_unix(window.started_at)

      1..count//1
      |> Enum.map(fn n ->
        key = {channel.seed, stamp, minute, n}

        %{
          id: Payloads.uuid({:chat, key}),
          at: DateTime.add(start, rem(:erlang.phash2({key, :at}), 60_000), :millisecond),
          sender_id: Enum.at(chatters, rem(:erlang.phash2({key, :sender}), length(chatters))),
          content: Enum.at(@lines, rem(:erlang.phash2({key, :line}), length(@lines))),
          reply?: rem(:erlang.phash2({key, :reply}), 20) == 0,
          key: key
        }
      end)
      |> Enum.sort_by(&DateTime.to_unix(&1.at, :millisecond))
      |> link_replies()
    end
  end

  # A reply points at an earlier message of the same minute; the first
  # message of a minute has nothing to reply to, so it stays a message.
  defp link_replies(messages) do
    {linked, _earlier} =
      Enum.map_reduce(messages, [], fn message, earlier ->
        reply_to =
          if message.reply? and earlier != [] do
            original =
              Enum.at(earlier, rem(:erlang.phash2({message.key, :original}), length(earlier)))

            %{id: original.id, sender_id: original.sender_id, content: original.content}
          end

        linked = message |> Map.drop([:reply?, :key]) |> Map.put(:reply_to, reply_to)
        {linked, [message | earlier]}
      end)

    linked
  end

  defp minute_of(window, at),
    do: at |> DateTime.diff(window.started_at, :second) |> max(0) |> div(60)

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
