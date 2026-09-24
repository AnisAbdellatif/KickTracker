defmodule Sim.Recorder.RetryAnalysis do
  @moduledoc """
  Answers "does Kick retry failed webhook deliveries, how often and for how
  long?" (project.md §16) from the deliveries captured while the capture
  server answered 500 on purpose. Pure.
  """

  @type delivery :: %{message_id: String.t(), at_ms: integer(), status: integer()}

  @spec summarize([delivery()]) :: map()
  def summarize(deliveries) do
    per_message =
      deliveries
      |> Enum.group_by(& &1.message_id)
      |> Map.new(fn {id, ds} -> {id, describe(Enum.sort_by(ds, & &1.at_ms))} end)

    retried = per_message |> Map.values() |> Enum.filter(&(&1["attempts"] > 1))

    %{
      "messages" => map_size(per_message),
      "deliveries" => length(deliveries),
      "messages_retried" => length(retried),
      "messages_never_accepted" =>
        per_message |> Map.values() |> Enum.count(&(not &1["accepted"])),
      "max_attempts" =>
        per_message |> Map.values() |> Enum.map(& &1["attempts"]) |> Enum.max(fn -> 0 end),
      # For the n-th retry, every delay (seconds after the previous attempt) seen.
      "delay_by_retry" => delay_by_retry(retried),
      "per_message" => per_message
    }
  end

  defp describe(deliveries) do
    times = Enum.map(deliveries, & &1.at_ms)

    %{
      "attempts" => length(deliveries),
      "statuses" => Enum.map(deliveries, & &1.status),
      "accepted" => Enum.any?(deliveries, &(&1.status in 200..299)),
      "delays_s" =>
        times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> (b - a) / 1000 end),
      "span_s" => (List.last(times) - hd(times)) / 1000
    }
  end

  defp delay_by_retry(retried) do
    retried
    |> Enum.flat_map(fn m -> m["delays_s"] |> Enum.with_index(1) end)
    |> Enum.group_by(fn {_delay, n} -> Integer.to_string(n) end, fn {delay, _n} -> delay end)
    |> Map.new(fn {n, delays} -> {n, Enum.sort(delays)} end)
  end
end
