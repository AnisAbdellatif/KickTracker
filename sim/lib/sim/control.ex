defmodule Sim.Control do
  @moduledoc """
  What the control API can do to a running simulation, as pure functions
  from one scenario to the next. Nothing here talks to processes or the
  network; `Sim.Http.Control` applies the results.

  Everything is an override layered over the schedule and stored with the
  channel (`Sim.Scenario.Channel` `overrides`), so the simulation stays a
  function of time: a stream started by hand is a window like any other,
  and asking about that moment again gives the same answer.
  """

  alias Sim.{Payloads, Scenario, Schedule}
  alias Sim.Scenario.Channel

  @known_faults ~w(drop_webhooks duplicate_webhooks pusher_disconnect_after_s)a

  @type error :: {:error, atom() | {atom(), term()}}

  @doc "Starts a stream now, for `minutes`, on a channel that is offline."
  @spec go_live(Scenario.t(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, Scenario.t()} | error()
  def go_live(scenario, slug, now, minutes \\ 120) do
    with {:ok, channel} <- fetch(scenario, slug),
         :ok <- offline!(channel, now),
         :ok <- positive!(minutes) do
      started_at = DateTime.truncate(now, :second)

      window = %{
        started_at: started_at,
        ends_at: DateTime.add(started_at, minutes * 60, :second),
        duration_s: minutes * 60
      }

      {:ok, update(scenario, channel, &update_in(&1.overrides.manual, fn m -> [window | m] end))}
    end
  end

  @doc "Ends the running stream now, whether it was scheduled or started by hand."
  @spec go_offline(Scenario.t(), String.t(), DateTime.t()) :: {:ok, Scenario.t()} | error()
  def go_offline(scenario, slug, now) do
    with {:ok, channel} <- fetch(scenario, slug),
         {:ok, window} <- live!(channel, now) do
      now = DateTime.truncate(now, :second)
      manual? = Enum.any?(channel.overrides.manual, &same_start?(&1, window))

      channel =
        if manual? do
          update_in(channel.overrides.manual, fn windows ->
            Enum.map(windows, &if(same_start?(&1, window), do: %{&1 | ends_at: now}, else: &1))
          end)
        else
          update_in(
            channel.overrides.cuts,
            &[%{started_at: window.started_at, ended_at: now} | &1]
          )
        end

      {:ok, update(scenario, channel, fn _ -> channel end)}
    end
  end

  @doc """
  Changes the running stream's title and/or category from now on. The
  category must be one of the channel's, by id.
  """
  @spec set_metadata(Scenario.t(), String.t(), DateTime.t(), map()) ::
          {:ok, Scenario.t()} | error()
  def set_metadata(scenario, slug, now, attrs) do
    with {:ok, channel} <- fetch(scenario, slug),
         {:ok, window} <- live!(channel, now),
         {:ok, change} <- metadata_change(channel, attrs) do
      override = Map.merge(change, %{at: now, window_started_at: window.started_at})

      {:ok,
       update(scenario, channel, &update_in(&1.overrides.metadata, fn m -> [override | m] end))}
    end
  end

  @doc "Replaces the faults, rejecting any name the simulator doesn't know."
  @spec set_faults(Scenario.t(), map()) :: {:ok, Scenario.t()} | error()
  def set_faults(scenario, faults) do
    faults = Map.new(faults, fn {k, v} -> {to_fault(k), v} end)

    case Enum.find(Map.keys(faults), &(&1 not in @known_faults)) do
      nil ->
        faults = Map.reject(faults, fn {_k, v} -> is_nil(v) end)
        {:ok, %{scenario | faults: faults}}

      unknown ->
        {:error, {:unknown_fault, unknown}}
    end
  end

  @doc """
  A single event built on demand: the webhook name and body, ready to
  deliver. Types: `follow`, `sub`, `resub`, `gift`, `kicks`, `ban`,
  `redemption`.
  """
  @spec event(Scenario.t(), String.t(), String.t(), map(), DateTime.t()) ::
          {:ok, {String.t(), map()}} | error()
  def event(scenario, slug, type, params, now) do
    with {:ok, channel} <- fetch(scenario, slug) do
      user = params["user_id"] || someone(channel, now)
      build(type, channel, user, params, now)
    end
  end

  @doc "One chat message sent now, as `Sim.Chat` would produce it."
  @spec chat(Scenario.t(), String.t(), String.t(), pos_integer() | nil, DateTime.t()) ::
          {:ok, {Channel.t(), Sim.Chat.message()}} | error()
  def chat(scenario, slug, content, sender_id, now) do
    with {:ok, channel} <- fetch(scenario, slug),
         {:ok, _window} <- live!(channel, now),
         :ok <- text!(content) do
      sender_id = sender_id || someone(channel, now)

      # The sender is part of the id: two people can send the same text in
      # the same millisecond, and they are two messages.
      message = %{
        id: Payloads.uuid({:manual_chat, channel.seed, now, sender_id, content}),
        at: now,
        sender_id: sender_id,
        content: content,
        reply_to: nil
      }

      {:ok, {channel, message}}
    end
  end

  @doc "The names of the faults the simulator understands."
  @spec known_faults() :: [atom()]
  def known_faults, do: @known_faults

  defp build("follow", channel, user, _params, _now),
    do: {:ok, {"channel.followed", Payloads.followed(channel, user)}}

  defp build("sub", channel, user, _params, now),
    do: {:ok, {"channel.subscription.new", Payloads.subscription(channel, user, 1, now)}}

  defp build("resub", channel, user, params, now) do
    with {:ok, months} <- int(params, "months", 3) do
      {:ok, {"channel.subscription.renewal", Payloads.subscription(channel, user, months, now)}}
    end
  end

  defp build("gift", channel, user, params, now) do
    with {:ok, count} <- int(params, "count", 5) do
      gifter = if params["anonymous"], do: nil, else: user

      giftees =
        for n <- 1..count, do: channel.user_id + 1_000_000 + :erlang.phash2({now, n}, 1_000_000)

      {:ok,
       {"channel.subscription.gifts",
        Payloads.subscription_gifts(channel, gifter, Enum.uniq(giftees), now)}}
    end
  end

  defp build("kicks", channel, user, params, now) do
    with {:ok, amount} <- int(params, "amount", 100) do
      {:ok, {"kicks.gifted", Payloads.kicks_gifted(channel, user, amount, now)}}
    end
  end

  defp build("ban", channel, user, params, now),
    do:
      {:ok,
       {"moderation.banned", Payloads.banned(channel, user, params["permanent"] == true, now)}}

  defp build("redemption", channel, user, _params, now) do
    reward = %{"id" => "reward-manual", "title" => "Manual redemption", "cost" => 100}

    {:ok,
     {"channel.reward.redemption.updated", Payloads.reward_redemption(channel, user, reward, now)}}
  end

  defp build(type, _channel, _user, _params, _now), do: {:error, {:unknown_event, type}}

  defp metadata_change(channel, attrs) do
    title = attrs["title"]
    category_id = attrs["category_id"]

    category =
      category_id && Enum.find(channel.categories, &(&1.id == category_id))

    cond do
      is_nil(title) and is_nil(category_id) ->
        {:error, :nothing_to_change}

      not is_nil(title) and not (is_binary(title) and title != "") ->
        {:error, :bad_title}

      not is_nil(category_id) and is_nil(category) ->
        {:error, {:unknown_category, category_id}}

      true ->
        {:ok, %{title: title, category: category} |> Map.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp fetch(scenario, slug) do
    case Scenario.channel(scenario, slug) do
      nil -> {:error, :unknown_channel}
      channel -> {:ok, channel}
    end
  end

  defp live!(channel, now) do
    case Schedule.stream_at(channel, now) do
      nil -> {:error, :not_live}
      window -> {:ok, window}
    end
  end

  defp offline!(channel, now),
    do: if(Schedule.live?(channel, now), do: {:error, :already_live}, else: :ok)

  defp positive!(n) when is_integer(n) and n > 0, do: :ok
  defp positive!(_), do: {:error, :bad_minutes}

  defp text!(content) when is_binary(content) and content != "", do: :ok
  defp text!(_), do: {:error, :bad_content}

  defp int(params, key, default) do
    case Map.get(params, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:bad_param, key}}
    end
  end

  # Someone from the channel's audience, like the scheduled events use.
  defp someone(channel, now),
    do: channel.user_id + 1 + :erlang.phash2({channel.seed, now}, Sim.Curve.pool_size(channel))

  defp update(scenario, channel, fun) do
    %{
      scenario
      | channels:
          Enum.map(scenario.channels, &if(&1.slug == channel.slug, do: fun.(&1), else: &1))
    }
  end

  defp to_fault(k) when is_atom(k), do: k

  defp to_fault(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp same_start?(a, b), do: DateTime.compare(a.started_at, b.started_at) == :eq
end
