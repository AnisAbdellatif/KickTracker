defmodule Sim.Recorder.Probe do
  @moduledoc """
  Candidate endpoints from Kick's undocumented website API (listed in the
  community repo fb-sean/kick-website-endpoints), to find out which still
  answer, which need auth, and what they return. Pure: builds the request
  list and describes responses; `mix record.probe` does the requests.

  Only read-only endpoints that could feed the tracker are probed. Anything
  needing a user login (moderation, payments, internal chatroom data) is
  left out on purpose.
  """

  @type bases :: %{api: String.t(), site: String.t()}

  @type ids :: %{
          slug: String.t(),
          user_id: integer() | nil,
          channel_id: integer() | nil,
          livestream_id: integer() | nil
        }

  @type candidate :: %{
          name: String.t(),
          url: String.t(),
          params: keyword(),
          why: String.t(),
          token_retry: boolean()
        }

  # Which id an endpoint wants isn't documented, so endpoints taking `:id`
  # are tried with both the user id and the channel id.
  #
  # `bases` are the configured hosts: `api` for api.kick.com, `site` for
  # kick.com (never hard-coded, AGENTS.md §6).
  @spec candidates(ids(), bases()) :: [candidate()]
  def candidates(%{slug: slug} = ids, bases) do
    slug = URI.encode(slug)
    private = fn name, path, opts -> candidate(name, bases.api <> path, true, opts) end
    site = fn name, path, opts -> candidate(name, bases.site <> path, false, opts) end

    [
      private.("followers-count-by-channel-id", "/channels/#{ids.channel_id}/followers-count",
        need: ids.channel_id,
        why: "follower total without v2"
      ),
      private.("followers-count-by-user-id", "/channels/#{ids.user_id}/followers-count",
        need: ids.user_id,
        why: "follower total without v2"
      ),
      private.(
        "viewer-count-by-channel-id",
        "/private/v0/channels/#{ids.channel_id}/viewer-count",
        need: ids.channel_id,
        why: "viewer count; refresh rate vs the public API"
      ),
      private.("viewer-count-by-user-id", "/private/v0/channels/#{ids.user_id}/viewer-count",
        need: ids.user_id,
        why: "viewer count; refresh rate vs the public API"
      ),
      private.("private-channel", "/private/v1/channels/#{slug}", why: "richer channel data?"),
      private.("private-channel-clips", "/private/v1/channels/#{slug}/clips", why: "clips"),
      private.("private-livestreams", "/private/v1/livestreams",
        why: "all live streams, for rankings"
      ),
      site.("current-viewers", "/current-viewers",
        params: [{:"ids[]", ids.livestream_id}],
        need: ids.livestream_id,
        why: "viewer counts for several streams at once"
      ),
      site.("v2-leaderboards", "/api/v2/channels/#{slug}/leaderboards",
        why: "gift/sub history before tracking"
      ),
      site.("v2-videos-latest", "/api/v2/channels/#{slug}/videos/latest", why: "past streams"),
      site.("v2-videos", "/api/v2/channels/#{slug}/videos", why: "past streams (full list?)"),
      site.("v2-clips", "/api/v2/channels/#{slug}/clips", why: "clips per channel"),
      site.("v2-livestream", "/api/v2/channels/#{slug}/livestream", why: "livestream details"),
      site.("v2-subscribers-last", "/api/v2/channels/#{slug}/subscribers/last",
        why: "latest subscriber"
      ),
      site.("v2-chatroom", "/api/v2/channels/#{slug}/chatroom", why: "chat settings"),
      site.("v1-channel", "/api/v1/channels/#{slug}",
        why: "older channel endpoint, compare with v2"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp candidate(name, url, token_retry, opts) do
    if Keyword.has_key?(opts, :need) and is_nil(opts[:need]) do
      nil
    else
      %{
        name: name,
        url: url,
        params: Keyword.get(opts, :params, []),
        why: opts[:why],
        token_retry: token_retry
      }
    end
  end

  @doc "The kick.com base, derived from the configured v2 URL (`https://kick.com/api/v2` → `https://kick.com`)."
  @spec site_base(String.t()) :: String.t()
  def site_base(v2_url), do: String.replace(v2_url, ~r{/api/v2/?$}, "")

  @doc "Whether a response means \"try again with our app token\"."
  @spec retry_with_token?(candidate(), integer()) :: boolean()
  def retry_with_token?(%{token_retry: true}, status) when status in [401, 403], do: true
  def retry_with_token?(_candidate, _status), do: false

  @doc """
  Summarizes one recorded response without any values: status, whether it's
  JSON, its top-level keys, and the paths of fields that look like counts we
  care about (followers, viewers, subscribers).
  """
  @spec describe(map()) :: map()
  def describe(%{"response" => %{"status" => status, "headers" => headers, "body" => body}}) do
    content_type =
      Enum.find_value(headers, "", fn [k, v] -> if String.downcase(k) == "content-type", do: v end)

    base = %{"status" => status, "content_type" => content_type, "bytes" => byte_size(body)}

    case Jason.decode(body) do
      {:ok, decoded} ->
        Map.merge(base, %{
          "json" => true,
          "top_level" => top_level(decoded),
          "count_fields" => decoded |> count_fields([]) |> Enum.sort() |> Enum.uniq()
        })

      {:error, _} ->
        Map.merge(base, %{
          "json" => false,
          "looks_like" =>
            if(body =~ ~r/cloudflare|cf-chl|Just a moment/i,
              do: "cloudflare challenge",
              else: "other"
            )
        })
    end
  end

  defp top_level(%{} = map), do: map |> Map.keys() |> Enum.sort()
  defp top_level(list) when is_list(list), do: "list of #{length(list)}"
  defp top_level(other), do: other |> json_type()

  defp json_type(v) when is_integer(v) or is_float(v), do: "number"
  defp json_type(v) when is_binary(v), do: "string"
  defp json_type(_), do: "other"

  @count_words ~w(follower viewer subscriber count)

  defp count_fields(%{} = map, path) do
    Enum.flat_map(map, fn {key, value} ->
      here = [key | path]
      own = if number?(value) and count_key?(key), do: [path_string(here)], else: []
      own ++ count_fields(value, here)
    end)
  end

  defp count_fields(list, path) when is_list(list),
    do: list |> Enum.take(3) |> Enum.flat_map(&count_fields(&1, ["[]" | path]))

  defp count_fields(_other, _path), do: []

  defp count_key?(key), do: String.contains?(String.downcase(key), @count_words)
  defp number?(v), do: is_integer(v) or is_float(v)
  defp path_string(path), do: path |> Enum.reverse() |> Enum.join(".")
end
