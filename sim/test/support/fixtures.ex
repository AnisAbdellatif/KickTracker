defmodule Sim.Fixtures do
  @moduledoc """
  Reads the anonymized recordings in `fixtures/` so tests can check the
  simulator against the shapes the real Kick actually sent.
  """

  @root "../fixtures"

  @doc "The decoded response bodies of every fixture whose name matches `pattern`."
  @spec bodies(String.t()) :: [term()]
  def bodies(pattern) do
    @root
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(&(get_in(&1, ["response", "status"]) == 200))
    |> Enum.map(&Jason.decode!(get_in(&1, ["response", "body"])))
  end

  @doc "The decoded request bodies of every recorded webhook of this event type."
  @spec webhook_bodies(String.t()) :: [map()]
  def webhook_bodies(event_type) do
    @root
    |> Path.join("webhook/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(fn rec ->
      Enum.any?(rec["request"]["headers"], &(&1 == ["kick-event-type", event_type]))
    end)
    |> Enum.map(&Jason.decode!(&1["request"]["body"]))
  end

  @doc """
  Every field path in a document, as dotted strings with `[]` for list
  elements. Comparing path sets is how a simulated payload is checked
  against a real one without depending on the values.
  """
  @spec paths(term()) :: MapSet.t()
  def paths(value), do: value |> collect([]) |> MapSet.new()

  defp collect(%{} = map, path) when map_size(map) == 0, do: [join(path)]

  defp collect(%{} = map, path),
    do: Enum.flat_map(map, fn {key, value} -> collect(value, [key | path]) end)

  defp collect([], path), do: [join(path)]

  defp collect(list, path) when is_list(list),
    do: Enum.flat_map(list, &collect(&1, ["[]" | path]))

  defp collect(_leaf, path), do: [join(path)]

  defp join(path), do: path |> Enum.reverse() |> Enum.join(".")
end
