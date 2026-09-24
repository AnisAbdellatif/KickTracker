defmodule KickTracker.Bulk do
  @moduledoc """
  Bulk mode (project.md §17.2, §20 step 13b): months of history from the
  fake Kick, written straight into the raw tables, so the site can be built
  on realistic data without waiting for it to be collected.

  Everything comes from the simulator's pure, time-addressable functions
  (`Sim.Schedule.windows_between/3`, `Sim.Curve`, `Sim.StreamState`,
  `Sim.Events`, `Sim.Chat`), not from running it forward. The rows are the
  ones live collection would have written: streams closed by Kick's end
  event, a viewer sample every 60s, title and category changes, follower
  readings (15 minutes live, daily offline, at each start and end),
  subscriber totals every 5 minutes, follows, subs, gifts and Kicks, and
  chat per minute. Only streams that ended before `to` are written; a
  stream live at `to` is left to live collection.

  Development only: it lives in `dev/`, which production never compiles.
  Running it twice over the same range is harmless (every insert ignores
  rows already there), but it is meant for an empty database.
  """

  import Ecto.Query

  alias KickTracker.{KickUsers, Repo, Rollups, Stats}
  alias KickTracker.Channels.Channel
  alias KickTracker.Metrics.{ChatMinutes, Sessionizer}
  alias Sim.{Chat, Curve, Events, Payloads, Schedule, StreamState}

  @doc """
  Writes history for every channel in `scenario` between `from` and `to`.
  Options: `chat: false` skips chat (the slowest part for big channels),
  `log: fun` receives progress lines.
  """
  @spec run(Sim.Scenario.t(), DateTime.t(), DateTime.t(), keyword()) :: map()
  def run(scenario, from, to, opts \\ []) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    from = Sessionizer.norm(from)
    to = Sessionizer.norm(to)

    totals =
      for sim <- scenario.channels, reduce: %{streams: 0, samples: 0, messages: 0} do
        acc ->
          channel = channel_row(sim, from)
          result = channel_history(channel, sim, from, to, opts)

          log.(
            "#{sim.slug}: #{result.streams} streams, #{result.samples} viewer samples, #{result.messages} chat messages"
          )

          Map.merge(acc, result, fn _k, a, b -> a + b end)
      end

    log.("rollups")
    weeks(from, to) |> Enum.each(fn {a, b} -> Rollups.hourly(a, b) end)
    Rollups.recent_stream_stats(from)
    totals
  end

  defp channel_row(sim, from) do
    Repo.insert_all(
      Channel,
      [
        %{
          kick_user_id: sim.user_id,
          kick_channel_id: sim.channel_id,
          chatroom_id: sim.chatroom_id,
          slug: sim.slug,
          timezone: "Etc/UTC",
          tracked_since: from,
          active: true,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: :kick_user_id
    )

    channel = Repo.get_by!(Channel, kick_user_id: sim.user_id)

    Repo.insert_all("channel_slugs", [%{channel_id: channel.id, slug: sim.slug, seen_from: from}],
      on_conflict: :nothing
    )

    channel
  end

  defp channel_history(channel, sim, from, to, opts) do
    windows =
      sim
      |> Schedule.windows_between(from, to)
      |> Enum.filter(&(not DateTime.before?(&1.started_at, from) and not DateTime.after?(&1.ends_at, to)))

    results = Enum.map(windows, &stream(channel, sim, &1, opts))

    followers(channel, sim, windows, from, to)
    subscribers(channel, sim, from, to)
    coverage(channel, from, to, opts)

    %{
      streams: length(windows),
      samples: Enum.sum_by(results, & &1.samples),
      messages: Enum.sum_by(results, & &1.messages)
    }
  end

  # --- one stream --------------------------------------------------------------

  defp stream(channel, sim, window, opts) do
    started_at = Sessionizer.norm(window.started_at)
    ended_at = Sessionizer.norm(window.ends_at)
    stream_id = Stats.apply_stream(channel.id, {:close, started_at, ended_at, :event})

    samples = viewer_samples(channel, sim, window, stream_id)
    changes(sim, window, stream_id)
    facts(channel, sim, window)
    messages = if Keyword.get(opts, :chat, true), do: chat(channel, sim, window, stream_id), else: 0

    %{samples: samples, messages: messages}
  end

  # A reading every 60s, starting a few seconds in (the poll isn't aligned
  # with the stream), each carrying the category showing then.
  defp viewer_samples(channel, sim, window, stream_id) do
    offset = 5 + rem(:erlang.phash2({sim.seed, window.started_at}), 50)

    rows =
      Stream.iterate(DateTime.add(window.started_at, offset), &DateTime.add(&1, 60))
      |> Enum.take_while(&DateTime.before?(&1, window.ends_at))
      |> Enum.map(fn at ->
        segment = StreamState.at(sim, window, at)

        %{
          channel_id: channel.id,
          observed_at: Sessionizer.norm(at),
          stream_id: stream_id,
          viewers: Payloads.viewers(sim, window, at),
          category_id: segment.category.id
        }
      end)

    rows |> Enum.chunk_every(5_000) |> Enum.each(&Stats.insert_samples("viewer_samples", &1))
    length(rows)
  end

  # What the stream started with, then each segment's title and category,
  # as `livestream.metadata.updated` would have reported them.
  defp changes(sim, window, stream_id) do
    [first | rest] = StreamState.segments(sim, window)
    at = Sessionizer.norm(DateTime.add(window.started_at, 2))

    initial =
      for {field, value} <- [
            {"title", first.title},
            {"category", Integer.to_string(first.category.id)},
            {"language", sim.language},
            {"mature", "false"}
          ] do
        %{field: field, old_value: nil, new_value: value, occurred_at: at, source: :event}
      end

    {later, _} =
      Enum.flat_map_reduce(rest, first, fn segment, previous ->
        at = Sessionizer.norm(segment.from)

        changed =
          [
            {"title", previous.title, segment.title},
            {"category", category_id(previous), category_id(segment)}
          ]
          |> Enum.reject(fn {_f, old, new} -> old == new end)
          |> Enum.map(fn {f, old, new} ->
            %{field: f, old_value: old, new_value: new, occurred_at: at, source: :event}
          end)

        {changed, segment}
      end)

    for segment <- [first | rest], segment.category do
      Stats.upsert_category(%{id: segment.category.id, name: segment.category.name}, at)
    end

    Stats.insert_changes(stream_id, initial ++ later)
  end

  defp category_id(%{category: nil}), do: nil
  defp category_id(%{category: c}), do: Integer.to_string(c.id)

  # Follows, subs, gifts and Kicks, minute by minute, at a moment inside
  # each minute.
  defp facts(channel, sim, window) do
    minutes = div(window.duration_s, 60)
    stamp = DateTime.to_unix(window.started_at)

    {follows, support, users} =
      for minute <- 0..(minutes - 1)//1, reduce: {[], [], []} do
        {follows, support, users} ->
          start = DateTime.add(window.started_at, minute * 60)
          viewers = Payloads.viewers(sim, window, start)

          sim
          |> Events.for_minute(viewers, minute)
          |> Enum.with_index()
          |> Enum.reduce({follows, support, users}, fn {event, i}, acc ->
            id = "bulk:#{sim.user_id}:#{stamp}:#{minute}:#{i}"
            at = Sessionizer.norm(DateTime.add(start, rem(:erlang.phash2(id), 60)))
            fact(event, id, channel.id, at, acc)
          end)
      end

    follows |> Enum.chunk_every(5_000) |> Enum.each(&Repo.insert_all("follows", &1, on_conflict: :nothing))

    support
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all("support_events", &1, on_conflict: :nothing))

    users |> Enum.chunk_every(5_000) |> Enum.each(&KickUsers.upsert/1)
  end

  defp fact({:follow, user}, id, channel_id, at, {f, s, u}),
    do:
      {[%{message_id: id, channel_id: channel_id, occurred_at: at, user_id: user} | f], s,
       [{user, "chatter#{user}", at} | u]}

  defp fact({kind, user, months}, id, channel_id, at, {f, s, u}) when kind in [:sub, :resub],
    do: {f, [support(id, channel_id, at, Atom.to_string(kind), user, months, nil) | s], [{user, "chatter#{user}", at} | u]}

  defp fact({:gift, gifter, giftees}, id, channel_id, at, {f, s, u}) do
    row = %{support(id, channel_id, at, "gift", gifter, length(giftees), nil) | payload: %{"giftee_ids" => giftees, "anonymous" => gifter == nil}}
    named = for user <- List.wrap(gifter) ++ giftees, do: {user, "chatter#{user}", at}
    {f, [row | s], named ++ u}
  end

  defp fact({:kicks, user, amount}, id, channel_id, at, {f, s, u}),
    do: {f, [support(id, channel_id, at, "kicks", user, amount, tier(amount)) | s], [{user, "chatter#{user}", at} | u]}

  # Bans and redemptions aren't tracked.
  defp fact(_other, _id, _channel_id, _at, acc), do: acc

  defp support(id, channel_id, at, kind, user, quantity, tier) do
    %{
      message_id: id,
      channel_id: channel_id,
      occurred_at: at,
      kind: kind,
      user_id: user,
      quantity: quantity,
      tier: tier,
      payload: %{}
    }
  end

  defp tier(amount) when amount >= 500, do: "legendary"
  defp tier(amount) when amount >= 100, do: "epic"
  defp tier(amount) when amount >= 50, do: "rare"
  defp tier(_amount), do: "common"

  # Chat per minute and per chatter; ids and times only.
  defp chat(channel, sim, window, stream_id) do
    minutes = div(window.duration_s, 60)

    # Bucketed by each message's own clock minute, as live collection does.
    per_minute =
      for minute <- 0..(minutes - 1)//1, m <- Chat.minute(sim, window, minute) do
        {Sessionizer.norm(m.at), m.sender_id}
      end
      |> Enum.group_by(fn {at, _} -> ChatMinutes.minute_of(at) end)
      |> Enum.map(fn {minute, messages} ->
        users =
          Enum.reduce(messages, %{}, fn {at, sender}, acc ->
            Map.update(acc, sender, %{messages: 1, first_at: at, last_at: at}, fn u ->
              %{
                messages: u.messages + 1,
                first_at: Enum.min([u.first_at, at], DateTime),
                last_at: Enum.max([u.last_at, at], DateTime)
              }
            end)
          end)

        %{minute: minute, users: users, count: length(messages)}
      end)

    minute_users =
      for m <- per_minute, {user, u} <- m.users,
          do: %{channel_id: channel.id, minute: m.minute, user_id: user, messages: u.messages}

    minutes_rows =
      for m <- per_minute,
          do: %{
            channel_id: channel.id,
            minute: m.minute,
            stream_id: stream_id,
            messages: m.count,
            chatters: map_size(m.users)
          }

    stream_users =
      per_minute
      |> Enum.flat_map(fn m -> Map.to_list(m.users) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {user, parts} ->
        %{
          stream_id: stream_id,
          user_id: user,
          messages: Enum.sum_by(parts, & &1.messages),
          first_at: parts |> Enum.map(& &1.first_at) |> Enum.min(DateTime),
          last_at: parts |> Enum.map(& &1.last_at) |> Enum.max(DateTime)
        }
      end)

    insert("chat_minute_users", minute_users)
    insert("chat_minutes", minutes_rows)
    insert("chat_stream_users", stream_users)

    stream_users
    |> Enum.map(&{&1.user_id, "chatter#{&1.user_id}", &1.last_at})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&KickUsers.upsert/1)

    Enum.sum_by(per_minute, & &1.count)
  end

  # --- the rest ----------------------------------------------------------------

  # Every 15 minutes while live, and at each start and end; at noon UTC on
  # days without a stream reading.
  defp followers(channel, sim, windows, from, to) do
    live =
      Enum.flat_map(windows, fn w ->
        Stream.iterate(DateTime.add(w.started_at, 30), &DateTime.add(&1, 900))
        |> Enum.take_while(&DateTime.before?(&1, w.ends_at))
        |> Kernel.++([DateTime.add(w.ends_at, 30)])
      end)

    live_days = MapSet.new(live, &DateTime.to_date/1)

    daily =
      for date <- Date.range(DateTime.to_date(from), DateTime.to_date(to)),
          not MapSet.member?(live_days, date),
          at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC"),
          not DateTime.before?(at, from) and DateTime.before?(at, to),
          do: at

    (live ++ daily)
    |> Enum.map(&%{channel_id: channel.id, observed_at: Sessionizer.norm(&1), followers: Curve.followers(sim, &1)})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Stats.insert_samples("follower_samples", &1))
  end

  defp subscribers(channel, sim, from, to) do
    Stream.iterate(from, &DateTime.add(&1, 300))
    |> Enum.take_while(&DateTime.before?(&1, to))
    |> Enum.map(fn at ->
      %{
        channel_id: channel.id,
        observed_at: at,
        active: sim.subscribers.active,
        active_gifted: sim.subscribers.gifted,
        canceled: sim.subscribers.canceled
      }
    end)
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Stats.insert_samples("subscriber_samples", &1))
  end

  # The whole range was "collected": one period per source.
  defp coverage(channel, from, to, opts) do
    sources =
      ["api", "subscribers", "followers", "ingress"] ++
        if(Keyword.get(opts, :chat, true), do: ["chat"], else: [])

    unless Repo.exists?(from c in "coverage", where: c.channel_id == ^channel.id and c.from_at == ^from) do
      Repo.insert_all(
        "coverage",
        for(s <- sources, do: %{channel_id: channel.id, source: s, from_at: from, to_at: to, ok: true})
      )
    end
  end

  defp insert(table, rows) do
    rows |> Enum.chunk_every(5_000) |> Enum.each(&Repo.insert_all(table, &1, on_conflict: :nothing))
  end

  defp weeks(from, to) do
    Stream.iterate(from, &DateTime.add(&1, 7 * 86_400))
    |> Enum.take_while(&DateTime.before?(&1, to))
    |> Enum.map(&{&1, Enum.min([DateTime.add(&1, 7 * 86_400 - 1), to], DateTime)})
  end
end
