defmodule KickTracker.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs`, read as a release reads it at boot, with settings
  left empty in an env file (`HEARTBEAT_URL=`): they count as unset,
  rather than an empty URL being used and an empty number failing to parse.
  """

  use ExUnit.Case, async: false

  @empty ~w(HEARTBEAT_URL ALERT_WEBHOOK_URL SHADOW_DATABASE_URL MAIN_DATABASE_URL KICK_PUBLIC_KEY BACKFILL_DAYS COLLECTOR_STATUS_PORT)

  setup do
    saved = Map.new(@empty, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    for name <- @empty, do: System.put_env(name, "")
    :ok
  end

  test "a setting set to nothing is not set" do
    config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :dev)
    app = config[:kick_tracker]

    assert app[:alerts][:heartbeat_url] == nil
    assert app[:alerts][:webhook_url] == nil
    assert app[:kick][:public_key] == nil
    assert app[:collector][:shadow_database_url] == nil
    assert app[:collector][:main_database_url] == nil
    assert app[:collector][:backfill_days] == 7
    assert app[:collector][:status_port] == 4101
  end
end
