defmodule KickTracker.Metrics.ChatMinutes do
  @moduledoc """
  A channel's chat, gathered minute by minute (project.md §3.4, §12.3).
  Pure.

  Each message counts for the minute of Kick's own timestamp, by sender.
  A minute is handed out for writing once it is safely over
  (`@settle_s` after its end), so a message arriving a little late still
  counts in its minute. The same message id seen twice (a resubscription,
  a second socket) counts once. Nothing about a message but its sender,
  id and time is kept.
  """

  @settle_s 30

  # `seen`: message ids per minute, dropped with their minute.
  defstruct minutes: %{}, seen: %{}, usernames: %{}

  @type t :: %__MODULE__{}
  @type minute :: %{
          minute: DateTime.t(),
          users: %{
            integer() => %{messages: pos_integer(), first_at: DateTime.t(), last_at: DateTime.t()}
          }
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds one message."
  @spec add(t(), %{
          id: String.t() | nil,
          sender_id: integer(),
          username: String.t() | nil,
          at: DateTime.t()
        }) :: t()
  def add(%__MODULE__{} = state, %{sender_id: sender, at: at} = message) do
    minute = minute_of(at)
    ids = Map.get(state.seen, minute, MapSet.new())
    id = message[:id]

    if id != nil and MapSet.member?(ids, id) do
      state
    else
      users =
        state.minutes
        |> Map.get(minute, %{})
        |> Map.update(sender, %{messages: 1, first_at: at, last_at: at}, fn u ->
          %{
            messages: u.messages + 1,
            first_at: earlier(u.first_at, at),
            last_at: later(u.last_at, at)
          }
        end)

      usernames =
        if is_binary(message[:username]),
          do: Map.put(state.usernames, sender, {message.username, at}),
          else: state.usernames

      %{
        state
        | minutes: Map.put(state.minutes, minute, users),
          seen: if(id, do: Map.put(state.seen, minute, MapSet.put(ids, id)), else: state.seen),
          usernames: usernames
      }
    end
  end

  @doc """
  Takes the minutes that are over as of `now`, oldest first, and the
  usernames seen in them (`{id, username, at}`). They are removed from the
  state, and so are the message ids remembered for them.
  """
  @spec take_done(t(), DateTime.t()) :: {[minute()], [{integer(), String.t(), DateTime.t()}], t()}
  def take_done(%__MODULE__{} = state, now) do
    cutoff = DateTime.add(now, -(60 + @settle_s))

    {done, open} =
      Enum.split_with(state.minutes, fn {minute, _} -> not DateTime.after?(minute, cutoff) end)

    done_minutes = Enum.map(done, &elem(&1, 0))
    senders = done |> Enum.flat_map(fn {_, users} -> Map.keys(users) end) |> MapSet.new()

    {usernames, kept_names} =
      Enum.split_with(state.usernames, fn {id, _} -> MapSet.member?(senders, id) end)

    rows =
      done
      |> Enum.sort_by(&elem(&1, 0), DateTime)
      |> Enum.map(fn {minute, users} -> %{minute: minute, users: users} end)

    {rows, Enum.map(usernames, fn {id, {name, at}} -> {id, name, at} end),
     %{
       state
       | minutes: Map.new(open),
         seen: Map.drop(state.seen, done_minutes),
         usernames: Map.new(kept_names)
     }}
  end

  @doc "The start of the minute `at` falls in."
  @spec minute_of(DateTime.t()) :: DateTime.t()
  def minute_of(%DateTime{} = at) do
    %{at | second: 0, microsecond: {0, 6}}
  end

  defp earlier(a, b), do: if(DateTime.before?(b, a), do: b, else: a)
  defp later(a, b), do: if(DateTime.after?(b, a), do: b, else: a)
end
