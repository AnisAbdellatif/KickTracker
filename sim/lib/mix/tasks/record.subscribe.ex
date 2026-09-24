defmodule Mix.Tasks.Record.Subscribe do
  @shortdoc "Manages the recorder's webhook subscriptions on the real Kick"

  @moduledoc """
  Subscribes channels to webhook events with the app token, lists current
  subscriptions, or removes them all. Deliveries go to the webhook URL set in
  the Kick app's settings (see `mix help record.webhooks`).

      mix record.subscribe --slugs <channel>,<other-channel> # all events except chat
      mix record.subscribe --slugs <channel> --with-chat     # also chat.message.sent
      mix record.subscribe --list
      mix record.subscribe --delete-all

  Whether sub, gift and Kicks events work with the app token for a channel
  that hasn't authorized us (project.md §16) shows in the recorded response:
  Kick reports an `error` per event it refuses.

  Output: `sim/recordings/<time>-subscribe/`.
  """

  use Mix.Task

  alias Sim.Recorder.{Config, Kick, Store}

  @events ~w(
    livestream.status.updated
    livestream.metadata.updated
    channel.followed
    channel.subscription.new
    channel.subscription.renewal
    channel.subscription.gifts
    kicks.gifted
    moderation.banned
    channel.reward.redemption.updated
  )

  @switches [slugs: :string, with_chat: :boolean, list: :boolean, delete_all: :boolean]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("subscribe")
    token = Kick.token!(config, run)

    cond do
      opts[:list] -> list(config, run, token)
      opts[:delete_all] -> delete_all(config, run, token)
      opts[:slugs] -> subscribe(config, run, token, opts)
      true -> Mix.raise("pass --slugs, --list or --delete-all")
    end
  end

  defp subscribe(config, run, token, opts) do
    slugs = Mix.Tasks.Record.Api.parse_slugs!(opts[:slugs])
    events = if opts[:with_chat], do: @events ++ ["chat.message.sent"], else: @events

    for channel <- Kick.channels_by_slugs(config, run, token, slugs) do
      results = Kick.subscribe(config, run, token, channel["broadcaster_user_id"], events)
      Mix.shell().info("#{channel["slug"]} (#{channel["broadcaster_user_id"]}):")

      for result <- results do
        line = "  #{result["name"]} v#{result["version"]}: "

        case result["error"] do
          nil -> Mix.shell().info(line <> "ok #{result["subscription_id"]}")
          error -> Mix.shell().error(line <> "refused: #{inspect(error)}")
        end
      end
    end

    Mix.shell().info("done: #{run}")
  end

  defp list(config, run, token) do
    subs = Kick.list_subscriptions(config, run, token)

    for sub <- subs do
      Mix.shell().info(
        "#{sub["id"]}  #{sub["broadcaster_user_id"]}  #{sub["event"]} v#{sub["version"]}  #{sub["method"]}"
      )
    end

    Mix.shell().info("#{length(subs)} subscriptions")
  end

  defp delete_all(config, run, token) do
    ids = config |> Kick.list_subscriptions(run, token) |> Enum.map(& &1["id"])
    status = Kick.unsubscribe(config, run, token, ids)
    Mix.shell().info("deleted #{length(ids)} subscriptions (HTTP #{status})")
  end
end
