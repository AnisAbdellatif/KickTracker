defmodule Mix.Tasks.Record.Probe do
  @shortdoc "Probes Kick's undocumented website endpoints once each (run by hand, real Kick)"

  @moduledoc """
  Requests each candidate endpoint from `Sim.Recorder.Probe` once, for one
  channel, and records the answers: which still work, which need auth or are
  blocked, and what they return. One request per second.

      mix record.probe --slug <channel>

  Pick a channel that is **live**, so livestream endpoints have something to
  return. Run it from home and from the VPS: whether the `api.kick.com`
  follower count answers from a datacenter decides whether it can replace v2.

  An `api.kick.com` endpoint that answers 401/403 is tried once more with our
  app token; both answers are recorded.

  Output: `sim/recordings/<time>-probe/`, and `summary.json` with, per
  endpoint, the status, content type, top-level keys and count-like fields
  (names only, no values).
  """

  use Mix.Task

  alias Sim.Recorder.{Config, HTTP, Kick, Probe, Store}

  @pause_ms 1_000

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [slug: :string])
    slug = opts[:slug] || Mix.raise("--slug is required, e.g. --slug <channel>")

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("probe")
    token = Kick.token!(config, run)

    ids = resolve_ids(config, run, token, slug)

    Mix.shell().info(
      "ids: user #{present(ids.user_id)}, channel #{present(ids.channel_id)}, " <>
        "livestream #{present(ids.livestream_id)}"
    )

    results =
      for candidate <-
            Probe.candidates(ids, %{api: config.api_url, site: Probe.site_base(config.v2_url)}) do
        Process.sleep(@pause_ms)
        first = request(config, run, candidate, nil, candidate.name)

        attempts =
          if Probe.retry_with_token?(candidate, HTTP.status(first)) do
            Process.sleep(@pause_ms)

            [
              {"without token", first},
              {"with app token",
               request(config, run, candidate, token, candidate.name <> "-with-token")}
            ]
          else
            [{"without token", first}]
          end

        described = Enum.map(attempts, fn {label, rec} -> {label, Probe.describe(rec)} end)
        report(candidate, described)
        {candidate.name, %{"why" => candidate.why, "attempts" => Map.new(described)}}
      end

    File.write!(
      Path.join(run, "summary.json"),
      Jason.encode_to_iodata!(Map.new(results), pretty: true)
    )

    Mix.shell().info("done: #{run}")
  end

  defp resolve_ids(config, run, token, slug) do
    user_id =
      case Kick.channels_by_slugs(config, run, token, [slug]) do
        [%{"broadcaster_user_id" => id} | _] -> id
        _ -> nil
      end

    v2 = Kick.v2_channel(config, run, slug) || %{}

    %{
      slug: slug,
      user_id: user_id || v2["user_id"],
      channel_id: v2["id"],
      livestream_id: get_in(v2, ["livestream", "id"])
    }
  end

  defp request(config, run, candidate, token, name) do
    Kick.record!(config, run, "probe", name, :get, candidate.url,
      token: token,
      params: candidate.params
    )
  end

  defp report(candidate, described) do
    line =
      Enum.map_join(described, "; ", fn {label, d} ->
        kind = if d["json"], do: "json", else: d["looks_like"]
        "#{label}: #{d["status"]} #{kind}" <> count_note(d)
      end)

    Mix.shell().info("#{String.pad_trailing(candidate.name, 32)} #{line}")
  end

  defp count_note(%{"count_fields" => [_ | _] = fields}),
    do: " (#{Enum.join(Enum.take(fields, 4), ", ")})"

  defp count_note(_), do: ""

  defp present(nil), do: "not found"
  defp present(_), do: "found"
end
