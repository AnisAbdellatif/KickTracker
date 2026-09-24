defmodule KickTracker.Events.Shape do
  @moduledoc """
  Whether a webhook still looks the way we parse it (project.md §19.2):
  a known event type and version, and the fields each handler reads.
  Pure. A problem doesn't stop the event from being stored (it is kept in
  `webhook_events` whatever happens, and can be replayed once handled);
  it is counted in `payload_issues` and alerted, so a change on Kick's
  side is noticed the day it happens rather than as missing data later.
  """

  alias KickTracker.Events.Envelope

  @known ~w(
    livestream.status.updated livestream.metadata.updated channel.followed
    channel.subscription.new channel.subscription.renewal channel.subscription.gifts
    kicks.gifted moderation.banned channel.reward.redemption.updated chat.message.sent
  )

  # The fields each handled type must carry, as paths and a type check.
  @required %{
    "livestream.status.updated" => [{["is_live"], :boolean}, {["started_at"], :string}],
    "livestream.metadata.updated" => [{["metadata"], :map}, {["metadata", "title"], :string}],
    "channel.followed" => [{["follower", "user_id"], :integer}],
    "channel.subscription.new" => [
      {["subscriber", "user_id"], :integer},
      {["duration"], :integer}
    ],
    "channel.subscription.renewal" => [
      {["subscriber", "user_id"], :integer},
      {["duration"], :integer}
    ],
    "channel.subscription.gifts" => [{["giftees"], :list}],
    "kicks.gifted" => [{["gift", "amount"], :integer}]
  }

  @doc "The problems with an event's shape; `[]` when it is as expected."
  @spec check(Envelope.t()) :: [String.t()]
  def check(%Envelope{event_type: type, event_version: version} = e) do
    cond do
      type not in @known ->
        ["unknown event type"]

      version != "1" ->
        ["unknown version #{version}"]

      true ->
        case Envelope.payload(e) do
          {:ok, body} when is_map(body) -> fields(type, body)
          _ -> ["body is not a JSON object"]
        end
    end
  end

  defp fields(type, body) do
    checks = [{["broadcaster", "user_id"], :integer} | Map.get(@required, type, [])]

    for {path, kind} <- checks, not kind?(get_in(body, path), kind) do
      "#{Enum.join(path, ".")} is not #{article(kind)}"
    end
  rescue
    # A path through something that isn't a map.
    _ -> ["unexpected nesting"]
  end

  defp kind?(v, :integer), do: is_integer(v)
  defp kind?(v, :string), do: is_binary(v)
  defp kind?(v, :boolean), do: is_boolean(v)
  defp kind?(v, :map), do: is_map(v)
  defp kind?(v, :list), do: is_list(v)

  defp article(:integer), do: "an integer"
  defp article(kind), do: "a #{kind}"
end
