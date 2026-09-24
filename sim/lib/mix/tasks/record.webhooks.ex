defmodule Mix.Tasks.Record.Webhooks do
  @shortdoc "Captures real Kick webhook deliveries through a tunnel (run by hand)"

  @moduledoc """
  Starts a local HTTP server that records every webhook delivery (headers and
  raw body), checks its signature against Kick's public key, and answers
  according to the chosen policy.

  Kick sends webhooks to the URL set in **the app's settings on Kick**, so:

    1. Start a tunnel to the port, e.g. `cloudflared tunnel --url http://localhost:4040`.
    2. Put the tunnel's URL in the Kick app's webhook setting.
    3. Subscribe channels: `mix record.subscribe --slugs <channel>`.
    4. Run this task and wait for events (or trigger them: go live, follow…).

  Normal capture (answer 200 to everything):

      mix record.webhooks --minutes 60

  Retry test (project.md §16): answer 500 to everything for 10 minutes, then
  200, and see whether and when Kick delivers again:

      mix record.webhooks --minutes 60 --fail-for 600

  Or answer 500 to the first 3 attempts of each message:

      mix record.webhooks --minutes 60 --fail-first 3

  Output: `sim/recordings/<time>-webhooks/`, plus `summary.json` with the
  retry analysis. Stop early with Ctrl-C twice (the summary is then skipped;
  the deliveries are already on disk).
  """

  use Mix.Task

  alias Sim.Recorder.{Config, Kick, RetryAnalysis, Store, WebhookCapture, WebhookPolicy}

  @switches [port: :integer, minutes: :integer, fail_for: :integer, fail_first: :integer]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    port = Keyword.get(opts, :port, 4040)
    minutes = Keyword.get(opts, :minutes, 60)

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("webhooks")

    public_key = System.get_env("KICK_PUBLIC_KEY") || Kick.public_key(config, run)

    if public_key == nil,
      do:
        Mix.shell().error("no public key: deliveries are recorded but signatures aren't checked")

    {:ok, policy} =
      WebhookPolicy.start_link(
        fail_for_s: Keyword.get(opts, :fail_for, 0),
        fail_first: Keyword.get(opts, :fail_first, 0)
      )

    {:ok, _server} =
      Bandit.start_link(
        plug: {WebhookCapture, run: run, policy: policy, public_key: public_key},
        port: port,
        ip: :loopback
      )

    Mix.shell().info(
      "listening on http://localhost:#{port} for #{minutes} min; recording into #{run}"
    )

    Process.sleep(minutes * 60_000)

    deliveries = WebhookPolicy.deliveries(policy)
    summary = RetryAnalysis.summarize(deliveries)
    File.write!(Path.join(run, "summary.json"), Jason.encode_to_iodata!(summary, pretty: true))

    Mix.shell().info(
      "done: #{summary["deliveries"]} deliveries, #{summary["messages"]} messages, " <>
        "#{summary["messages_retried"]} retried (max #{summary["max_attempts"]} attempts). See #{run}/summary.json"
    )
  end
end
