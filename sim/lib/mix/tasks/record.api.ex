defmodule Mix.Tasks.Record.Api do
  @shortdoc "Records Kick's public API for a few channels (run by hand, real Kick)"

  @moduledoc """
  Records the official public API for the given channels:

    * the token response (token redacted) and the webhook public key;
    * `/channels` by slug;
    * `/livestreams`, polled every `--interval` seconds for `--minutes`, to
      measure how often `viewer_count` actually changes (project.md §16);
    * a few error responses: an unknown slug, a request without a token.

  Every response keeps all its headers, so rate-limit headers are captured.

      mix record.api --slugs <channel>,<other-channel> --minutes 10 --interval 15

  Pick channels that are **live** for the polling part to mean anything.
  Output: `sim/recordings/<time>-api/`, plus `summary.json`.
  """

  use Mix.Task

  alias Sim.Recorder.{Config, Kick, Store, ViewerRefresh}

  @switches [slugs: :string, minutes: :integer, interval: :integer]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    slugs = parse_slugs!(opts[:slugs])
    minutes = Keyword.get(opts, :minutes, 10)
    interval = max(Keyword.get(opts, :interval, 15), 5)

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("api")

    token = Kick.token!(config, run)
    public_key? = Kick.public_key(config, run, token) != nil
    channels = Kick.channels_by_slugs(config, run, token, slugs)
    ids = channels |> Enum.map(& &1["broadcaster_user_id"]) |> Enum.filter(&is_integer/1)

    Mix.shell().info(
      "resolved #{length(ids)}/#{length(slugs)} channels; public key: #{public_key?}"
    )

    # Error shapes, once each.
    Kick.channels_by_slugs(config, run, token, [
      "kick-tracker-no-such-channel-#{System.unique_integer([:positive])}"
    ])

    Kick.record!(
      config,
      run,
      "public_api",
      "livestreams-no-token",
      :get,
      config.api_url <> "/public/v1/livestreams"
    )

    series = poll(config, run, token, ids, minutes, interval)

    summary = %{
      "slugs" => slugs,
      "interval_s" => interval,
      "minutes" => minutes,
      "viewer_refresh" =>
        Map.new(series, fn {id, samples} -> {to_string(id), ViewerRefresh.summarize(samples)} end),
      "rate_limit_headers" => rate_limit_headers(run)
    }

    File.write!(Path.join(run, "summary.json"), Jason.encode_to_iodata!(summary, pretty: true))
    Mix.shell().info("done: #{run}")
    Mix.shell().info(Jason.encode!(summary["viewer_refresh"], pretty: true))
  end

  defp poll(_config, _run, _token, [], _minutes, _interval), do: %{}

  defp poll(config, run, token, ids, minutes, interval) do
    deadline = System.monotonic_time(:millisecond) + minutes * 60_000
    do_poll(config, run, token, ids, interval, deadline, %{})
  end

  defp do_poll(config, run, token, ids, interval, deadline, acc) do
    at_ms = System.system_time(:millisecond)

    acc =
      config
      |> Kick.livestreams(run, token, ids, "livestreams-poll")
      |> Enum.flat_map(fn {_rec, data} -> data end)
      |> Enum.reduce(acc, fn stream, acc ->
        sample = %{at_ms: at_ms, viewers: stream["viewer_count"]}
        Map.update(acc, stream["broadcaster_user_id"], [sample], &[sample | &1])
      end)

    if System.monotonic_time(:millisecond) + interval * 1000 < deadline do
      Process.sleep(interval * 1000)
      do_poll(config, run, token, ids, interval, deadline, acc)
    else
      acc
    end
  end

  # Every response header that looks rate-limit related, with the values seen.
  defp rate_limit_headers(run) do
    Path.wildcard(Path.join([run, "public_api", "*.json"]))
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> Jason.decode!() |> get_in(["response", "headers"]) |> List.wrap()
    end)
    |> Enum.filter(fn [name, _] ->
      String.contains?(String.downcase(name), ["ratelimit", "rate-limit", "retry-after"])
    end)
    |> Enum.group_by(fn [name, _] -> String.downcase(name) end, fn [_, value] -> value end)
    |> Map.new(fn {name, values} -> {name, values |> Enum.uniq() |> Enum.take(10)} end)
  end

  @doc false
  def parse_slugs!(nil), do: Mix.raise("--slugs is required, e.g. --slugs <channel>,<other-channel>")

  def parse_slugs!(value) do
    case value
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> Mix.raise("--slugs is empty")
      slugs -> slugs
    end
  end
end
