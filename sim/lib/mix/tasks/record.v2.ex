defmodule Mix.Tasks.Record.V2 do
  @shortdoc "Records Kick's private v2 channel endpoint (run by hand, real Kick)"

  @moduledoc """
  Records `kick.com/api/v2/channels/<slug>` for each channel: the only source
  of the follower total. `playback_url` is redacted before anything reaches
  disk (AGENTS.md §6). Run it from the VPS as well as from home to answer
  whether v2 accepts datacenter IPs (project.md §16).

      mix record.v2 --slugs <channel>,<other-channel>

  Output: `sim/recordings/<time>-v2/`.
  """

  use Mix.Task

  alias Sim.Recorder.{Config, Kick, Store}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [slugs: :string])
    slugs = Mix.Tasks.Record.Api.parse_slugs!(opts[:slugs])

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("v2")

    for slug <- slugs do
      case Kick.v2_channel(config, run, slug) do
        %{"followers_count" => count} -> Mix.shell().info("#{slug}: followers_count #{count}")
        nil -> Mix.shell().error("#{slug}: no 200 answer (see the recording for status and body)")
        _ -> Mix.shell().error("#{slug}: answered, but without followers_count")
      end
    end

    Mix.shell().info("done: #{run}")
  end
end
