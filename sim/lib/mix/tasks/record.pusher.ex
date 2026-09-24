defmodule Mix.Tasks.Record.Pusher do
  @shortdoc "Records Kick's Pusher chat feed for one channel (run by hand, real Kick)"

  @moduledoc """
  Records every Pusher frame for one channel for `--minutes`: chat messages,
  and whatever else appears (raids, hosts, subs, polls…), so we learn the
  exact event names (project.md §16). The chatroom and channel ids are read
  from v2 unless given.

  Subscribes to `chatrooms.<chatroom>.v2` and `channel.<channel id>`, plus
  any `--extra` channel names (comma-separated) worth probing.

      mix record.pusher --slug <channel> --minutes 20
      mix record.pusher --slug <channel> --chatroom 123 --channel-id 456 --extra chatroom_123

  Pick a live, active channel. Output: `sim/recordings/<time>-pusher/`.
  """

  use Mix.Task

  alias Sim.Recorder.{Config, Kick, Pusher, Store}

  @switches [
    slug: :string,
    minutes: :integer,
    chatroom: :integer,
    channel_id: :integer,
    extra: :string
  ]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    slug = opts[:slug] || Mix.raise("--slug is required")
    minutes = Keyword.get(opts, :minutes, 10)

    Mix.Task.run("app.start")
    config = Config.load()
    run = Store.new_run("pusher")

    {chatroom, channel_id} = ids(config, run, slug, opts)

    channels =
      ["chatrooms.#{chatroom}.v2"] ++
        if(channel_id, do: ["channel.#{channel_id}"], else: []) ++
        String.split(opts[:extra] || "", ",", trim: true)

    Mix.shell().info("recording #{Enum.join(channels, ", ")} for #{minutes} min")

    result =
      Pusher.record(config.pusher_url,
        run: run,
        name: slug,
        channels: channels,
        deadline_ms: System.monotonic_time(:millisecond) + minutes * 60_000
      )

    case result do
      {:ok, frames} -> Mix.shell().info("done: #{frames} lines in #{run}/pusher")
      {:error, reason} -> Mix.raise("could not connect to Pusher: #{inspect(reason)}")
    end
  end

  defp ids(config, run, slug, opts) do
    case {opts[:chatroom], opts[:channel_id]} do
      {chatroom, channel_id} when is_integer(chatroom) ->
        {chatroom, channel_id}

      _ ->
        case Kick.v2_channel(config, run, slug) do
          %{"chatroom" => %{"id" => chatroom}, "id" => channel_id} ->
            {chatroom, channel_id}

          _ ->
            Mix.raise("couldn't read the chatroom id from v2; pass --chatroom (and --channel-id)")
        end
    end
  end
end
