defmodule Sim.Fixtures.Anonymizer do
  @moduledoc """
  Replaces personal data in decoded Kick payloads, consistently: the same
  real id, name or URL always gets the same fake one, across every file of a
  run and across runs (the mapping is persisted by the caller). Pure.

  Rules are by field name and context:

    * **ids** of people and channels (`user_id`, `broadcaster_user_id`,
      `chatroom_id`, `id` outside category/emote/badge/gift contexts…) become
      fake integers (or numeric strings, if they were strings);
    * **names** (`username`, `slug`, `channel_slug`, `display_name`, and
      `name` directly inside a person) become `user0001`-style pseudonyms,
      case-insensitively consistent;
    * **free text** (chat `content`, titles, descriptions, bios, reasons) and
      **social handles** become placeholders; empty strings stay empty;
    * **every URL** becomes `https://example.invalid/asset/N`;
    * category, subcategory, emote, badge and gift data is kept.

  Anything else is kept as is. Every kept string under a field not known to
  be safe is counted in `unknown` by its path (never its value), so a person
  can review the report before fixtures are committed.
  """

  defstruct ids: %{}, names: %{}, urls: %{}, texts: 0, unknown: %{}

  @type t :: %__MODULE__{}

  @keep_contexts ~w(category categories subcategory subcategories recent_categories
                    parent_category emote emotes badge badges gift reward identity_badges)
  @people ~w(user sender broadcaster follower gifter giftees subscriber redeemer
             moderator banned_user host hosted raider channel recipient chatroom owner)
  @id_keys ~w(id user_id broadcaster_user_id channel_id chatroom_id sender_id
              livestream_id owner_id)
  @name_keys ~w(username slug channel_slug display_name)
  @text_keys ~w(content message stream_title session_title title channel_description
                description bio reason offline_banner_text)
  @social_keys ~w(instagram twitter youtube discord tiktok facebook email website)
  @safe_keys ~w(event type language status method version color
                event_type kind direction access_token token_type playback_url
                code error message_id subscription_id duration tier gift_id
                created_at updated_at started_at ended_at expires_at
                redeemed_at start_time date at recorded_at)

  @first_id 900_000_001

  @spec new(map()) :: t()
  def new(saved \\ %{}) do
    %__MODULE__{
      ids: Map.get(saved, "ids", %{}),
      names: Map.get(saved, "names", %{}),
      urls: Map.get(saved, "urls", %{}),
      texts: Map.get(saved, "texts", 0)
    }
  end

  @doc "The mapping to persist between runs (contains real values: keep it out of git)."
  @spec to_saved(t()) :: map()
  def to_saved(%__MODULE__{} = s),
    do: %{"ids" => s.ids, "names" => s.names, "urls" => s.urls, "texts" => s.texts}

  @doc "Anonymizes a decoded JSON value. `path` is the list of keys above it, innermost first."
  @spec anonymize(term(), [String.t()], t()) :: {term(), t()}
  def anonymize(value, path \\ [], state)

  def anonymize(%{} = map, path, state) do
    Enum.reduce(map, {%{}, state}, fn {key, value}, {acc, state} ->
      {value, state} = field(key, value, path, state)
      {Map.put(acc, key, value), state}
    end)
  end

  def anonymize(list, path, state) when is_list(list) do
    {items, state} =
      Enum.map_reduce(list, state, fn item, state -> anonymize(item, ["[]" | path], state) end)

    {items, state}
  end

  def anonymize(value, _path, state), do: {value, state}

  defp field(key, value, path, state) do
    k = String.downcase(key)
    kept? = keep_context?(path)

    cond do
      is_binary(value) and url?(value) -> url(value, state)
      kept? -> anonymize(value, [k | path], state)
      k in @id_keys and id_like?(value) -> id(value, state)
      String.ends_with?(k, "_user_id") and id_like?(value) -> id(value, state)
      k in @name_keys and is_binary(value) -> name(value, state)
      k == "name" and is_binary(value) and person?(path) -> name(value, state)
      k == "message" and path == [] -> {value, state}
      k in @text_keys and is_binary(value) -> text(value, "text", state)
      k in @social_keys and is_binary(value) -> text(value, "handle", state)
      is_binary(value) -> {value, note_unknown(k, value, path, state)}
      true -> anonymize(value, [k | path], state)
    end
  end

  @doc "Maps one id (integer or numeric string) to its fake counterpart."
  @spec id(integer() | String.t(), t()) :: {integer() | String.t(), t()}
  def id(value, state) when is_integer(value) do
    key = Integer.to_string(value)

    case state.ids do
      %{^key => fake} ->
        {fake, state}

      ids ->
        fake = @first_id + map_size(ids)
        {fake, %{state | ids: Map.put(ids, key, fake)}}
    end
  end

  def id(value, state) when is_binary(value) do
    {fake, state} = id(String.to_integer(value), state)
    {Integer.to_string(fake), state}
  end

  @doc "Maps one username or slug to a pseudonym, ignoring case."
  @spec name(String.t(), t()) :: {String.t(), t()}
  def name("", state), do: {"", state}

  def name(value, state) do
    key = String.downcase(value)

    case state.names do
      %{^key => fake} ->
        {fake, state}

      names ->
        fake = "user" <> String.pad_leading(Integer.to_string(map_size(names) + 1), 4, "0")
        {fake, %{state | names: Map.put(names, key, fake)}}
    end
  end

  @doc """
  Replaces the numeric ids in a Pusher channel name with fake ids, e.g.
  `chatrooms.123.v2` or `chatroom_123`. Digits glued to a letter (the `2`
  in `v2`) are not ids and are kept.
  """
  @spec channel_name(String.t(), t()) :: {String.t(), t()}
  def channel_name(value, state) do
    ~r/(?<![A-Za-z0-9])\d+(?![A-Za-z])/
    |> Regex.split(value, include_captures: true)
    |> Enum.reduce({"", state}, fn part, {acc, state} ->
      if part =~ ~r/^\d+$/ do
        {fake, state} = id(part, state)
        {acc <> fake, state}
      else
        {acc <> part, state}
      end
    end)
  end

  defp url(value, state) do
    case state.urls do
      %{^value => fake} ->
        {fake, state}

      urls ->
        fake = "https://example.invalid/asset/#{map_size(urls) + 1}"
        {fake, %{state | urls: Map.put(urls, value, fake)}}
    end
  end

  defp text("", _kind, state), do: {"", state}

  defp text(_value, kind, state),
    do: {"#{kind}-#{state.texts + 1}", %{state | texts: state.texts + 1}}

  defp note_unknown(key, value, path, state) do
    if key in @safe_keys or timestamp?(value) or value == "" do
      state
    else
      at = [key | path] |> Enum.reverse() |> Enum.join(".")
      %{state | unknown: Map.update(state.unknown, at, 1, &(&1 + 1))}
    end
  end

  defp keep_context?(path), do: Enum.any?(path, &(&1 in @keep_contexts))
  defp person?([parent | _]), do: parent in @people
  defp person?(_), do: false

  defp id_like?(value) when is_integer(value), do: true
  defp id_like?(value) when is_binary(value), do: value =~ ~r/^\d{1,18}$/
  defp id_like?(_), do: false

  defp url?(value), do: value =~ ~r{^https?://}i
  defp timestamp?(value), do: value =~ ~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/
end
