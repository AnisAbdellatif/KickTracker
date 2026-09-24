defmodule Sim.Payloads do
  @moduledoc """
  Kick-shaped JSON built from simulated state. Pure.

  Every shape here is copied from the recordings in `fixtures/`, including
  the parts that would be easy to get wrong and that a tracker has to cope
  with: an offline channel's zero `start_time`, the category repeated under
  both `category` and `Category`, empty `key`/`url`, and second-precision
  timestamps.
  """

  alias Sim.{Curve, Schedule, StreamState}
  alias Sim.Scenario.Channel

  # What Kick sends for a channel that has never been live.
  @zero_time "0001-01-01T00:00:00Z"

  @doc "An app access token response (`POST /oauth/token`)."
  @spec token(String.t(), pos_integer()) :: map()
  def token(access_token, expires_in \\ 5_184_000) do
    %{"access_token" => access_token, "token_type" => "Bearer", "expires_in" => expires_in}
  end

  @doc "The webhook signing key (`GET /public/v1/public-key`)."
  @spec public_key(String.t()) :: map()
  def public_key(pem), do: ok(%{"public_key" => pem})

  @doc "One entry of `GET /public/v1/channels`."
  @spec channel(Channel.t(), DateTime.t()) :: map()
  def channel(%Channel{} = channel, at) do
    window = Schedule.stream_at(channel, at)
    segment = window && StreamState.at(channel, window, at)

    %{
      "broadcaster_user_id" => channel.user_id,
      "slug" => channel.slug,
      "channel_description" => "",
      "banner_picture" => asset(channel, "banner"),
      "stream_title" => (segment && segment.title) || "",
      "category" => category(segment && segment.category),
      "active_subscribers_count" => channel.subscribers.active,
      "active_gifted_subscribers_count" => channel.subscribers.gifted,
      "canceled_subscribers_count" => channel.subscribers.canceled,
      "stream" => stream_block(channel, window, at)
    }
  end

  @doc "One entry of `GET /public/v1/livestreams`; nil when the channel is offline."
  @spec livestream(Channel.t(), DateTime.t()) :: map() | nil
  def livestream(%Channel{} = channel, at) do
    case Schedule.stream_at(channel, at) do
      nil ->
        nil

      window ->
        segment = StreamState.at(channel, window, at)

        %{
          "broadcaster_user_id" => channel.user_id,
          "channel_id" => channel.channel_id,
          "slug" => channel.slug,
          "stream_title" => segment.title,
          "category" => category(segment.category),
          "language" => channel.language,
          "has_mature_content" => false,
          "started_at" => iso(window.started_at),
          "viewer_count" => viewers(channel, window, at),
          "thumbnail" => asset(channel, "thumbnail"),
          "profile_picture" => asset(channel, "profile")
        }
    end
  end

  @doc "`GET /api/v2/channels/{slug}`: only the fields a tracker reads, in Kick's shape."
  @spec v2_channel(Channel.t(), DateTime.t()) :: map()
  def v2_channel(%Channel{} = channel, at) do
    window = Schedule.stream_at(channel, at)
    segment = window && StreamState.at(channel, window, at)

    %{
      "id" => channel.channel_id,
      "user_id" => channel.user_id,
      "slug" => channel.slug,
      "is_banned" => false,
      "followers_count" => Curve.followers(channel, at),
      "playback_url" => "https://sim.invalid/playback/#{channel.slug}.m3u8?token=simulated",
      "chatroom" => %{
        "id" => channel.chatroom_id,
        "chatable_id" => channel.channel_id,
        "chatable_type" => "App\\Models\\Channel"
      },
      "user" => %{
        "id" => channel.user_id,
        "username" => channel.username,
        "profile_pic" => asset(channel, "profile")
      },
      "livestream" => v2_livestream(channel, window, segment, at)
    }
  end

  @doc "The body of a `livestream.status.updated` webhook."
  @spec status_updated(Channel.t(), Schedule.window(), DateTime.t(), boolean()) :: map()
  def status_updated(%Channel{} = channel, window, at, live?) do
    segment = StreamState.at(channel, window, at)

    %{
      "broadcaster" => broadcaster(channel),
      "is_live" => live?,
      "title" => segment.title,
      "started_at" => iso(window.started_at),
      "ended_at" => if(live?, do: nil, else: iso(at))
    }
  end

  @doc """
  The body of a `livestream.metadata.updated` webhook: a full snapshot, with
  the category under both `category` and `Category`, exactly as Kick sends
  it.
  """
  @spec metadata_updated(Channel.t(), Schedule.window(), DateTime.t()) :: map()
  def metadata_updated(%Channel{} = channel, window, at) do
    segment = StreamState.at(channel, window, at)
    category = category(segment.category)

    %{
      "broadcaster" => broadcaster(channel),
      "metadata" => %{
        "title" => segment.title,
        "language" => channel.language,
        "has_mature_content" => false,
        "category" => category,
        "Category" => category
      }
    }
  end

  @doc "The body of a `channel.followed` webhook."
  @spec followed(Channel.t(), pos_integer()) :: map()
  def followed(%Channel{} = channel, follower_id) do
    %{"broadcaster" => broadcaster(channel), "follower" => person(follower_id)}
  end

  @doc "A Pusher chat message frame's `data` (a JSON document inside a string)."
  @spec chat_message(Channel.t(), pos_integer(), String.t(), DateTime.t()) :: map()
  def chat_message(%Channel{} = channel, sender_id, content, at) do
    %{
      "id" => uuid(channel.seed, sender_id, at),
      "chatroom_id" => channel.chatroom_id,
      "content" => content,
      "type" => "message",
      "created_at" => iso(at),
      "sender" => %{
        "id" => sender_id,
        "username" => "chatter#{sender_id}",
        "slug" => "chatter#{sender_id}",
        "identity" => %{"color" => "#FF9D00", "badges" => []}
      }
    }
  end

  @doc "`{\"data\": …, \"message\": \"OK\"}`, Kick's envelope for public API answers."
  @spec ok(term()) :: map()
  def ok(data), do: %{"data" => data, "message" => "OK"}

  @doc "Kick's error envelope: `data` is an empty object, not a list."
  @spec error(String.t()) :: map()
  def error(message), do: %{"data" => %{}, "message" => message}

  @doc "A timestamp the way Kick writes them: UTC, whole seconds, `Z`."
  @spec iso(DateTime.t()) :: String.t()
  def iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "Viewers for this channel at this moment, or 0 when it is offline."
  @spec viewers(Channel.t(), Schedule.window() | nil, DateTime.t()) :: non_neg_integer()
  def viewers(_channel, nil, _at), do: 0

  def viewers(channel, window, at) do
    elapsed = DateTime.diff(at, window.started_at, :second)
    Curve.viewers(channel, elapsed, window.duration_s)
  end

  defp stream_block(_channel, nil, _at) do
    %{
      "is_live" => false,
      "is_mature" => false,
      "key" => "",
      "language" => "",
      "start_time" => @zero_time,
      "thumbnail" => "",
      "url" => "",
      "viewer_count" => 0
    }
  end

  defp stream_block(channel, window, at) do
    %{
      "is_live" => true,
      "is_mature" => false,
      "key" => "",
      "language" => channel.language,
      "start_time" => iso(window.started_at),
      "thumbnail" => asset(channel, "thumbnail"),
      "url" => "",
      "viewer_count" => viewers(channel, window, at)
    }
  end

  defp v2_livestream(_channel, nil, _segment, _at), do: nil

  defp v2_livestream(channel, window, segment, at) do
    %{
      "id" => livestream_id(channel, window),
      "slug" => "#{channel.slug}-#{DateTime.to_unix(window.started_at)}",
      "session_title" => segment.title,
      "is_live" => true,
      "start_time" => iso(window.started_at),
      "viewer_count" => viewers(channel, window, at),
      "categories" => [category(segment.category)]
    }
  end

  defp livestream_id(channel, window),
    do:
      4_000_000 +
        rem(:erlang.phash2({channel.seed, DateTime.to_unix(window.started_at)}), 1_000_000)

  defp broadcaster(channel) do
    %{
      "user_id" => channel.user_id,
      "username" => channel.username,
      "channel_slug" => channel.slug,
      "is_verified" => channel.verified,
      "is_anonymous" => false,
      "identity" => nil,
      "profile_picture" => asset(channel, "profile")
    }
  end

  defp person(user_id) do
    %{
      "user_id" => user_id,
      "username" => "chatter#{user_id}",
      "channel_slug" => "chatter#{user_id}",
      "is_verified" => false,
      "is_anonymous" => false,
      "identity" => nil,
      "profile_picture" => "https://sim.invalid/profile/#{user_id}.webp"
    }
  end

  defp category(nil), do: nil

  defp category(category) do
    %{
      "id" => category.id,
      "name" => category.name,
      "thumbnail" => "https://sim.invalid/category/#{category.slug}.webp"
    }
  end

  defp asset(channel, kind), do: "https://sim.invalid/#{kind}/#{channel.slug}.webp"

  # Shaped like the UUIDs Kick uses for chat messages, and stable per message.
  defp uuid(seed, sender_id, at) do
    <<a::32, b::16, c::16, d::16, e::48>> =
      :crypto.hash(:md5, "#{seed}-#{sender_id}-#{DateTime.to_unix(at, :millisecond)}")

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-8~3.16.0b-~12.16.0b", [
      a,
      b,
      rem(c, 4096),
      rem(d, 4096),
      e
    ])
    |> IO.iodata_to_binary()
  end
end
