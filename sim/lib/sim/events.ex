defmodule Sim.Events do
  @moduledoc """
  What happens in a channel during one minute of a stream: follows, subs,
  resubs, gift bursts and Kicks. Pure and deterministic from the channel's
  seed and the minute, so a scenario replays identically.

  Rates scale with the audience, and the rare things stay rare: a
  500-viewer stream sees a follow or two a minute, a sub every half hour or
  so, and a gift burst now and then. They are the events a tracker can only
  learn from webhooks, so the point is that they arrive irregularly rather
  than on a tidy schedule.
  """

  alias Sim.Scenario.Channel

  @type event ::
          {:follow, pos_integer()}
          | {:sub, pos_integer(), pos_integer()}
          | {:resub, pos_integer(), pos_integer()}
          | {:gift, pos_integer() | nil, [pos_integer()]}
          | {:kicks, pos_integer(), pos_integer()}
          | {:ban, pos_integer(), pos_integer(), boolean()}
          | {:redemption, pos_integer(), map()}

  # Roughly one per N viewers per minute. Tuned so a three-hour stream with
  # a few thousand viewers produces numbers a real channel would recognise:
  # hundreds of follows, tens of subs, a handful of gift bursts.
  @follow_per 1_200
  @sub_per 20_000
  @resub_per 15_000
  @gift_per 400_000
  @kicks_per 15_000
  @ban_per 150_000
  @redemption_per 40_000

  @kicks_amounts [10, 25, 50, 100, 200, 500]
  @rewards [
    %{"id" => "reward-hydrate", "title" => "Hydrate!", "cost" => 500},
    %{"id" => "reward-song", "title" => "Song request", "cost" => 2_000},
    %{"id" => "reward-highlight", "title" => "Highlight my message", "cost" => 100}
  ]

  @doc "Every event in the minute starting `minute` into a stream of `viewers`."
  @spec for_minute(Channel.t(), non_neg_integer(), non_neg_integer()) :: [event()]
  def for_minute(%Channel{} = channel, viewers, minute) do
    follows(channel, viewers, minute) ++
      subs(channel, viewers, minute) ++
      gifts(channel, viewers, minute) ++
      kicks(channel, viewers, minute) ++
      bans(channel, viewers, minute) ++
      redemptions(channel, viewers, minute)
  end

  defp follows(channel, viewers, minute) do
    for n <- 1..occurrences(channel, viewers, minute, :follow, @follow_per)//1 do
      {:follow, viewer(channel, minute, {:follow, n})}
    end
  end

  defp subs(channel, viewers, minute) do
    new =
      for n <- 1..occurrences(channel, viewers, minute, :sub, @sub_per)//1 do
        {:sub, viewer(channel, minute, {:sub, n}), 1}
      end

    renewals =
      for n <- 1..occurrences(channel, viewers, minute, :resub, @resub_per)//1 do
        months = 2 + rem(:erlang.phash2({channel.seed, minute, :months, n}), 30)
        {:resub, viewer(channel, minute, {:resub, n}), months}
      end

    new ++ renewals
  end

  defp gifts(channel, viewers, minute) do
    for n <- 1..occurrences(channel, viewers, minute, :gift, @gift_per)//1 do
      # Most gift bursts are a handful of subs; one in five is a big one.
      big? = rem(:erlang.phash2({channel.seed, minute, :giftsize, n}), 5) == 0
      spread = if big?, do: 45, else: 5

      count =
        if(big?, do: 5, else: 1) +
          rem(:erlang.phash2({channel.seed, minute, :giftcount, n}), spread)

      giftees = for i <- 1..count, do: viewer(channel, minute, {:giftee, n, i})
      # One gift burst in eight is anonymous, as Kick allows.
      gifter =
        if rem(:erlang.phash2({channel.seed, minute, :anon, n}), 8) == 0,
          do: nil,
          else: viewer(channel, minute, {:gifter, n})

      {:gift, gifter, Enum.uniq(giftees)}
    end
  end

  defp kicks(channel, viewers, minute) do
    for n <- 1..occurrences(channel, viewers, minute, :kicks, @kicks_per)//1 do
      amount =
        Enum.at(
          @kicks_amounts,
          rem(:erlang.phash2({channel.seed, minute, :amount, n}), length(@kicks_amounts))
        )

      {:kicks, viewer(channel, minute, {:kicks, n}), amount}
    end
  end

  # A moderator timing someone out. Rare, and more common in busy chat.
  defp bans(channel, viewers, minute) do
    for n <- 1..occurrences(channel, viewers, minute, :ban, @ban_per)//1 do
      permanent? = rem(:erlang.phash2({channel.seed, minute, :permanent, n}), 10) == 0
      {:ban, channel.user_id, viewer(channel, minute, {:banned, n}), permanent?}
    end
  end

  # Channel-point rewards. We don't track them, but they arrive all the
  # same, so the simulator sends them and the app has to cope.
  defp redemptions(channel, viewers, minute) do
    for n <- 1..occurrences(channel, viewers, minute, :redemption, @redemption_per)//1 do
      reward =
        Enum.at(
          @rewards,
          rem(:erlang.phash2({channel.seed, minute, :reward, n}), length(@rewards))
        )

      {:redemption, viewer(channel, minute, {:redeemer, n}), reward}
    end
  end

  # How many of something happen this minute. The whole part always happens;
  # the fraction is a deterministic chance, so rare events land on some
  # minutes and not others instead of never happening at all.
  defp occurrences(channel, viewers, minute, kind, per) do
    expected = viewers / per
    whole = trunc(expected)
    chance = rem(:erlang.phash2({channel.seed, minute, kind}), 1000) / 1000

    whole + if(chance < expected - whole, do: 1, else: 0)
  end

  # Someone from the channel's audience, the same pool the chatters come
  # from, so the people who follow and gift are people who were there.
  defp viewer(channel, minute, tag) do
    pool = Sim.Curve.pool_size(channel)
    channel.user_id + 1 + rem(:erlang.phash2({channel.seed, minute, tag}), pool)
  end
end
