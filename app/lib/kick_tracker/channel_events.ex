defmodule KickTracker.ChannelEvents do
  @moduledoc """
  Hosts (Kick's raids) as `channel_events` rows (project.md §16). Pure.

  A host shows on both sides: `StreamHostEvent` in the receiving channel's
  chatroom (`hosted_by`), `ChatMoveToSupportedChannelEvent` on the hosting
  channel's feed (`hosting`), under a second apart when both are tracked.
  Neither carries a time: `occurred_at` is when we received it.

    * `hosted_by`: `other_channel` is the host's `host_username` as Kick
      sends it (a username, whose case may differ from the slug's; match
      case-insensitively), `viewers` its `number_viewers`.
    * `hosting`: `other_channel` is the hosted channel's `slug`, `viewers`
      `hosted.viewers_count` (the viewers taken along: the hosting
      channel's own count at the time, the other side's `number_viewers`).

  Anything missing or of another type stays unknown (`nil`).

  `payload` keeps the event, its Pusher channel and only the fields read
  from it: the hosting side's data also carries the hosting channel itself
  (with its playback URL), its livestream, thumbnails and pictures, and the
  receiving side's the host's free-text `optional_message`; none of that is
  stored (fixtures: `fixtures/pusher/20260926T203429Z-pusher__*.jsonl`).
  """

  @kinds %{
    "App\\Events\\StreamHostEvent" => "hosted_by",
    "App\\Events\\ChatMoveToSupportedChannelEvent" => "hosting"
  }

  @doc "The row for one event received at `at`, without its channel."
  @spec row(String.t(), String.t() | nil, term(), DateTime.t()) :: map()
  def row(name, pusher_channel, data, %DateTime{} = at) do
    kind = Map.fetch!(@kinds, name)
    {other, viewers, kept} = parse(kind, if(is_map(data), do: data, else: %{}))

    %{
      occurred_at: at,
      kind: kind,
      other_channel: other,
      viewers: viewers,
      # The same frame at the same time is the same event (a replayed
      # journal, an import); the time keeps two identical hosts apart.
      # Hashed from the event as sent, before trimming, so rows stored
      # before this parser keep matching a replay of their event.
      dedup_key:
        :crypto.hash(:sha256, [
          DateTime.to_iso8601(at),
          0,
          Jason.encode!(%{"event" => name, "pusher_channel" => pusher_channel, "data" => data})
        ])
        |> Base.encode16(case: :lower),
      payload: %{"event" => name, "pusher_channel" => pusher_channel, "data" => kept}
    }
  end

  defp parse("hosted_by", data) do
    kept = Map.new(~w(chatroom_id host_username number_viewers), &{&1, data[&1]})
    {string(data["host_username"]), count(data["number_viewers"]), kept}
  end

  defp parse("hosting", data) do
    hosted = if is_map(data["hosted"]), do: data["hosted"], else: %{}

    kept = %{
      "slug" => data["slug"],
      "hosted" => Map.new(~w(slug username viewers_count), &{&1, hosted[&1]})
    }

    {string(data["slug"]) || string(hosted["slug"]), count(hosted["viewers_count"]), kept}
  end

  defp string(v) when is_binary(v) and v != "", do: v
  defp string(_), do: nil

  defp count(v) when is_integer(v) and v >= 0, do: v
  defp count(_), do: nil
end
