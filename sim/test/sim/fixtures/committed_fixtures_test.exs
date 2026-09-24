defmodule Sim.Fixtures.CommittedFixturesTest do
  @moduledoc """
  Checks the committed `fixtures/` themselves, with no raw recording at
  hand (AGENTS.md §6, §11): no UUID in them is a real one, and no record
  number the anonymizer maps is left unmapped.
  """
  use ExUnit.Case, async: true

  alias Sim.Fixtures.LeakCheck

  @root Path.expand("../../../../fixtures", __DIR__)

  defp documents do
    @root
    |> Path.join("**/*.{json,jsonl}")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      docs =
        if Path.extname(path) == ".jsonl",
          do: path |> File.stream!() |> Enum.map(&Jason.decode!/1),
          else: [path |> File.read!() |> Jason.decode!()]

      Enum.map(docs, &{Path.relative_to(path, @root), &1})
    end)
  end

  test "there are fixtures to check" do
    assert length(documents()) > 10
  end

  test "every UUID in the fixtures is one of the anonymizer's fakes" do
    leaks =
      for {file, doc} <- documents(),
          {path, count} <- LeakCheck.real_uuids(doc),
          do: "#{file}: #{path} (#{count})"

    assert leaks == []
  end

  test "every order_column in the fixtures is a fake id" do
    real =
      for {file, doc} <- documents(),
          n <- values(doc, "order_column"),
          n < 900_000_000,
          do: file

    assert real == []
  end

  defp values(%{} = map, key) do
    Enum.flat_map(map, fn
      {^key, v} when is_integer(v) -> [v]
      {_, v} -> values(v, key)
    end)
  end

  defp values(list, key) when is_list(list), do: Enum.flat_map(list, &values(&1, key))

  defp values(s, key) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> values(decoded, key)
      _ -> []
    end
  end

  defp values(_, _), do: []
end
