defmodule KickTracker.ChannelEvents do
  @moduledoc """
  Hosts (Kick's raids) as `channel_events` rows (project.md §16). Pure.

  A host shows on both sides: `StreamHostEvent` in the receiving channel's
  chatroom (`hosted_by`), `ChatMoveToSupportedChannelEvent` on the hosting
  channel's feed (`hosting`). Their fields haven't been seen yet, so each
  is kept as sent in `payload` (event name, Pusher channel, data), with
  `other_channel` and `viewers` left unknown until a parser written from
  real ones fills them.
  """

  @kinds %{
    "App\\Events\\StreamHostEvent" => "hosted_by",
    "App\\Events\\ChatMoveToSupportedChannelEvent" => "hosting"
  }

  @doc "The row for one event received at `at`, without its channel."
  @spec raw(String.t(), String.t() | nil, term(), DateTime.t()) :: map()
  def raw(name, pusher_channel, data, %DateTime{} = at) do
    payload = %{"event" => name, "pusher_channel" => pusher_channel, "data" => data}

    %{
      occurred_at: at,
      kind: Map.fetch!(@kinds, name),
      other_channel: nil,
      viewers: nil,
      # The same frame at the same time is the same event (a replayed
      # journal, an import); the time keeps two identical hosts apart.
      dedup_key:
        :crypto.hash(:sha256, [DateTime.to_iso8601(at), 0, Jason.encode!(payload)])
        |> Base.encode16(case: :lower),
      payload: payload
    }
  end
end
