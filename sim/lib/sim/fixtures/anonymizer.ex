defmodule Sim.Fixtures.Anonymizer do
  @moduledoc """
  Replaces personal data in decoded Kick payloads, consistently: the same
  real id, name or URL always gets the same fake one, across every file of a
  run and across runs (the mapping is persisted by the caller). Pure.

  Rules are by field name and context:

    * **ids**: `id` and every `*_id` key (except category, emote, badge,
      gift and reward ids), outside category/emote/badge/gift contexts,
      become fake integers (or numeric strings, if they were strings);
    * **names** (`username`, `slug`, `channel_slug`, `display_name`, and
      `name` directly inside a person) become `user0001`-style pseudonyms,
      case-insensitively consistent;
    * **free text** (chat `content`, titles, descriptions, bios, reasons) and
      **social handles** become placeholders; empty strings stay empty;
    * **every URL** becomes `https://example.invalid/asset/N`;
    * **UUIDs anywhere** and **string ids** (e.g. `channel_01abc…`) become
      consistent fakes of the same shape, so links between messages survive;
    * **cursors**, media **file names** and embedded **image data** are
      replaced;
    * category, subcategory, emote, badge and gift data is kept.

  Anything else is kept as is. Every kept string under a field not known to
  be safe is counted in `unknown` by its path (never its value), so a person
  can review the report before fixtures are committed.
  """

  defstruct ids: %{}, names: %{}, urls: %{}, tokens: %{}, texts: 0, unknown: %{}

  @type t :: %__MODULE__{}

  @keep_contexts ~w(category categories subcategory subcategories recent_categories
                    parent_category emote emotes badge badges badges_v2 gift reward identity_badges)
  @people ~w(user sender broadcaster follower gifter giftees subscriber redeemer
             moderator banned_user host hosted raider channel recipient chatroom owner)
  @id_keys ~w(id user_id broadcaster_user_id channel_id chatroom_id sender_id
              livestream_id owner_id)
  # Numbers under any other `*_id` key are mapped too (a missed id is a leak,
  # an extra mapping is harmless), except these, which identify no one.
  # `subscription_id` and `message_id` are ids Kick issues to our app for its
  # webhook subscriptions and deliveries; they also appear verbatim in the
  # webhook headers, and must match there.
  @safe_id_keys ~w(category_id subcategory_id parent_category_id emote_id badge_id
                   gift_id reward_id subscription_id message_id)
  @name_keys ~w(username slug channel_slug display_name)
  @text_keys ~w(content message stream_title session_title title channel_description
                description bio reason offline_banner_text file_name)
  @cursor_keys ~w(cursor next_cursor nextcursor prev_cursor previous_cursor)
  @image_data_keys ~w(base64svg)
  @social_keys ~w(instagram twitter youtube discord tiktok facebook email website)
  @safe_keys ~w(event type language status method version color
                event_type kind direction access_token token_type playback_url
                code error message_id subscription_id duration tier gift_id
                created_at updated_at started_at ended_at expires_at
                redeemed_at start_time date at recorded_at
                chat_mode chat_mode_old chatable_type socket_id message_ref
                lang_iso followers_count public_key collection_name conversions_disk
                disk mime_type model_type privacy amount)

  @first_id 900_000_001

  @spec new(map()) :: t()
  def new(saved \\ %{}) do
    %__MODULE__{
      ids: Map.get(saved, "ids", %{}),
      names: Map.get(saved, "names", %{}),
      urls: Map.get(saved, "urls", %{}),
      tokens: Map.get(saved, "tokens", %{}),
      texts: Map.get(saved, "texts", 0)
    }
  end

  @doc "The mapping to persist between runs (contains real values: keep it out of git)."
  @spec to_saved(t()) :: map()
  def to_saved(%__MODULE__{} = s),
    do: %{
      "ids" => s.ids,
      "names" => s.names,
      "urls" => s.urls,
      "tokens" => s.tokens,
      "texts" => s.texts
    }

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
      k in @image_data_keys and is_binary(value) -> {"[image data removed]", state}
      is_binary(value) and uuid?(value) -> token(value, state)
      kept? -> anonymize(value, [k | path], state)
      person_id_key?(k) and id_like?(value) -> id(value, state)
      k in @safe_id_keys and is_binary(value) -> {value, state}
      person_id_key?(k) and is_binary(value) and value != "" -> token(value, state)
      k in @cursor_keys and is_binary(value) -> text(value, "cursor", state)
      k in @name_keys and is_binary(value) -> name(value, state)
      k == "channel" and is_binary(value) and pusher_channel?(value) -> channel_name(value, state)
      k == "name" and is_binary(value) and person?(path) -> name(value, state)
      k == "name" and is_binary(value) and "media" in path -> text(value, "text", state)
      k == "message" and path == [] -> {value, state}
      k in @text_keys and is_binary(value) -> text(value, "text", state)
      k in @social_keys and is_binary(value) -> text(value, "handle", state)
      is_binary(value) and nested_json?(value) -> nested(value, [k | path], state)
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

  @doc """
  Maps an opaque string id to a consistent fake one. UUIDs stay UUID-shaped
  (so links between messages still work); prefixed ids like `channel_01abc…`
  keep their prefix (`channel_anon0001`).
  """
  @spec token(String.t(), t()) :: {String.t(), t()}
  def token(value, state) do
    case state.tokens do
      %{^value => fake} ->
        {fake, state}

      tokens ->
        n = map_size(tokens) + 1
        fake = fake_token(value, n)
        {fake, %{state | tokens: Map.put(tokens, value, fake)}}
    end
  end

  defp fake_token(value, n) do
    cond do
      uuid?(value) ->
        "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

      match = Regex.run(~r/^([a-z]+)_/, value) ->
        Enum.at(match, 1) <> "_anon" <> String.pad_leading(Integer.to_string(n), 4, "0")

      true ->
        "anon" <> String.pad_leading(Integer.to_string(n), 4, "0")
    end
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
    if key in @safe_keys or timestamp?(value) or event_name?(value) or value == "" do
      state
    else
      at = [key | path] |> Enum.reverse() |> Enum.join(".")
      %{state | unknown: Map.update(state.unknown, at, 1, &(&1 + 1))}
    end
  end

  # JSON stored as a string (Pusher's data, recorded bodies) is anonymized
  # inside and re-encoded. Checked after the text rules, so chat text that
  # happens to look like JSON is still replaced as text.
  defp nested(value, path, state) do
    {decoded, state} = value |> Jason.decode!() |> anonymize(path, state)
    {Jason.encode!(decoded), state}
  end

  defp nested_json?(<<c, _::binary>> = value) when c in [?{, ?[] do
    case Jason.decode(value) do
      {:ok, decoded} -> is_map(decoded) or is_list(decoded)
      _ -> false
    end
  end

  defp nested_json?(_), do: false

  defp keep_context?(path), do: Enum.any?(path, &(&1 in @keep_contexts))
  defp person?([parent | _]), do: parent in @people
  defp person?(_), do: false

  defp id_like?(value) when is_integer(value), do: true
  defp id_like?(value) when is_binary(value), do: value =~ ~r/^\d{1,18}$/
  defp id_like?(_), do: false

  defp url?(value), do: value =~ ~r{^https?://}i

  # Kick event names, e.g. `livestream.status.updated`.
  defp event_name?(value), do: value =~ ~r/^[a-z_]+(\.[a-z_]+)+$/

  defp person_id_key?(k),
    do: k in @id_keys or (String.ends_with?(k, "_id") and k not in @safe_id_keys)

  defp uuid?(value),
    do: value =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp pusher_channel?(value), do: value =~ ~r/^[a-z_]+[._]\d+/
  defp timestamp?(value), do: value =~ ~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/
end
