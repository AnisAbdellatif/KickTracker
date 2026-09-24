defmodule Sim.Fixtures.LeakCheck do
  @moduledoc """
  A second line of defence after `Sim.Fixtures.Anonymizer`, independent of
  its rules: collects the real names, chat texts and ids found in raw
  recordings and looks for each of them anywhere in the anonymized output.
  Pure. Reports field paths and counts, never values.

  What counts as sensitive here is deliberately simpler than the
  anonymizer's rules, so a gap in those rules shows up as a leak:

    * strings under `username`, `slug`, `channel_slug`, `display_name`;
    * strings of 6+ characters under `content`;
    * integers of 4+ digits under `id` or any `*_id` key;

  all outside category, emote, badge and gift data, which is kept on purpose.
  """

  @keep_contexts ~w(category categories subcategory subcategories recent_categories
                    parent_category emote emotes badge badges badges_v2 gift reward)
  @name_keys ~w(username slug channel_slug display_name)
  @safe_id_keys ~w(category_id subcategory_id parent_category_id emote_id badge_id
                   gift_id reward_id)

  @doc "Sensitive values in a decoded raw document, as `%{value => field path}`."
  @spec sensitive(term()) :: %{String.t() => String.t()}
  def sensitive(doc), do: collect(doc, [], %{})

  @doc """
  Given the sensitive values (from `sensitive/1`, merged over all raw files)
  and the anonymized documents, returns `%{field path => occurrences}` for
  every sensitive value still present. Empty means no leak.
  """
  @spec leaks(%{String.t() => String.t()}, [term()]) :: %{String.t() => pos_integer()}
  def leaks(sensitive, anonymized) when map_size(sensitive) == 0 or anonymized == [], do: %{}

  def leaks(sensitive, anonymized) do
    found = anonymized |> Enum.flat_map(&scalars/1) |> MapSet.new()

    sensitive
    |> Enum.filter(fn {value, _path} -> MapSet.member?(found, value) end)
    |> Enum.frequencies_by(fn {_value, path} -> path end)
  end

  defp collect(%{} = map, path, acc) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      field(String.downcase(key), value, path, acc)
    end)
  end

  defp collect(list, path, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect(&1, ["[]" | path], &2))

  defp collect(binary, path, acc) when is_binary(binary) do
    # JSON nested in a string (Pusher's data, recorded bodies).
    case nested_json(binary) do
      {:ok, decoded} -> collect(decoded, path, acc)
      :error -> acc
    end
  end

  defp collect(_other, _path, acc), do: acc

  defp field(key, value, path, acc) do
    here = [key | path]

    cond do
      Enum.any?(path, &(&1 in @keep_contexts)) ->
        acc

      key in @name_keys and is_binary(value) and byte_size(value) > 2 ->
        put(acc, value, here)

      key == "content" and is_binary(value) and String.length(value) >= 6 ->
        put(acc, value, here)

      id_key?(key) and is_integer(value) and value >= 1000 ->
        put(acc, Integer.to_string(value), here)

      true ->
        collect(value, here, acc)
    end
  end

  defp id_key?(key),
    do: key == "id" or (String.ends_with?(key, "_id") and key not in @safe_id_keys)

  defp put(acc, value, path) do
    acc
    |> Map.put_new(value, path_string(path))
    |> then(fn acc ->
      if value =~ ~r/^\d+$/,
        do: acc,
        else: Map.put_new(acc, String.downcase(value), path_string(path))
    end)
  end

  defp path_string(path), do: path |> Enum.reverse() |> Enum.join(".")

  # Every string and number in a document, including inside nested JSON
  # strings, with strings also split into words so a name embedded in a
  # longer string (a URL, a channel name) is still found.
  defp scalars(%{} = map), do: Enum.flat_map(map, fn {_k, v} -> scalars(v) end)
  defp scalars(list) when is_list(list), do: Enum.flat_map(list, &scalars/1)
  defp scalars(n) when is_integer(n), do: [Integer.to_string(n)]

  defp scalars(s) when is_binary(s) do
    nested =
      case nested_json(s) do
        {:ok, decoded} -> scalars(decoded)
        :error -> []
      end

    words = Regex.split(~r/[^\p{L}\p{N}_-]+/u, s, trim: true)
    [s, String.downcase(s) | words ++ Enum.map(words, &String.downcase/1)] ++ nested
  end

  defp scalars(_), do: []

  defp nested_json(<<c, _::binary>> = s) when c in [?{, ?[] do
    case Jason.decode(s) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end

  defp nested_json(_), do: :error
end
