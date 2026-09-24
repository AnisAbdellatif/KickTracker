defmodule Sim.ChatTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sim.{Chat, Curve, Fixtures, Payloads, Schedule}
  alias Sim.Scenario.Channel

  @channel Channel.new(
             slug: "somestreamer",
             peak_viewers: 600,
             schedule: %{days: [1], start_hour: 20, duration_min: 180}
           )
  @window Schedule.stream_at(@channel, ~U[2026-01-05 20:30:00Z])

  defp at(minutes), do: DateTime.add(@window.started_at, minutes * 60, :second)

  test "a minute's chat matches the audience's message rate and chatters" do
    messages = Chat.minute(@channel, @window, 30)
    viewers = Payloads.viewers(@channel, @window, at(30))

    assert length(messages) == Curve.messages_per_minute(@channel, viewers, 30 * 60)
    assert Enum.all?(messages, &(DateTime.compare(&1.at, at(30)) != :lt))
    assert Enum.all?(messages, &(DateTime.compare(&1.at, at(31)) == :lt))
    assert Enum.map(messages, & &1.at) == Enum.sort(Enum.map(messages, & &1.at), DateTime)
  end

  test "the same interval always gives the same messages, with the same ids" do
    a = Chat.between(@channel, @window, at(10), at(15))
    b = Chat.between(@channel, @window, at(10), at(15))

    assert a == b
    assert a != []
    assert length(Enum.uniq_by(a, & &1.id)) == length(a)
  end

  test "consecutive intervals split the chat without losing or repeating a message" do
    whole = Chat.between(@channel, @window, at(10), at(14))

    pieces =
      Enum.flat_map([{10, 11}, {11, 12.5}, {12.5, 14}], fn {from, to} ->
        Chat.between(@channel, @window, at_float(from), at_float(to))
      end)

    assert pieces == whole
  end

  defp at_float(minutes),
    do: DateTime.add(@window.started_at, round(minutes * 60_000), :millisecond)

  test "outside the stream the chat is silent" do
    before = DateTime.add(@window.started_at, -600, :second)

    assert Chat.between(@channel, @window, before, DateTime.add(@window.started_at, -1, :second)) ==
             []

    assert Chat.between(
             @channel,
             @window,
             @window.ends_at,
             DateTime.add(@window.ends_at, 600, :second)
           ) == []
  end

  test "some messages are replies, always to an earlier message of the same minute" do
    messages = for m <- 0..59, message <- Chat.minute(@channel, @window, m), do: message
    replies = Enum.filter(messages, & &1.reply_to)
    by_id = Map.new(messages, &{&1.id, &1})

    assert replies != []
    assert length(replies) < length(messages) / 5

    for reply <- replies do
      original = Map.fetch!(by_id, reply.reply_to.id)
      assert DateTime.compare(original.at, reply.at) != :gt
      assert original.sender_id == reply.reply_to.sender_id
      assert original.content == reply.reply_to.content
    end
  end

  test "the frame's data matches the recorded chat messages and replies, field for field" do
    real = Fixtures.pusher_chat_data()
    assert real != [], "no recorded chat messages to compare against"

    # Not every chatter has every badge, in the recordings or here, so our
    # side is every field seen across an hour of our messages.
    messages = for m <- 0..59, message <- Chat.minute(@channel, @window, m), do: message

    paths = fn ms ->
      ms
      |> Enum.map(&Fixtures.paths(Payloads.chat_message(@channel, &1)))
      |> Enum.reduce(&MapSet.union/2)
    end

    ours_plain = paths.(Enum.reject(messages, & &1.reply_to))
    ours_reply = paths.(Enum.filter(messages, & &1.reply_to))

    for recorded <- real do
      ours = if recorded["type"] == "reply", do: ours_reply, else: ours_plain
      missing = MapSet.difference(Fixtures.paths(recorded), ours)

      assert MapSet.size(missing) == 0,
             "chat #{recorded["type"]} missing: #{inspect(MapSet.to_list(missing))}"
    end
  end

  test "chat timestamps use Pusher's +00:00 form, unlike the API's Z" do
    [message | _] = Chat.minute(@channel, @window, 5)
    data = Payloads.chat_message(@channel, message)

    assert data["created_at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$/

    assert data["metadata"]["message_ref"] ==
             Integer.to_string(DateTime.to_unix(message.at, :millisecond))
  end

  property "any interval inside a stream gives well-formed, ordered messages" do
    check all(start <- integer(0..170), length <- integer(0..10)) do
      messages = Chat.between(@channel, @window, at(start), at(start + length))

      assert Enum.map(messages, & &1.at) == Enum.sort(Enum.map(messages, & &1.at), DateTime)
      assert Enum.all?(messages, &(is_binary(&1.content) and &1.content != ""))
      assert Enum.all?(messages, &(&1.sender_id > @channel.user_id))
    end
  end
end
