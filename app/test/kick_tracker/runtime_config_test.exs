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

  describe "the public URL in production" do
    # What production requires to read runtime.exs at all.
    @prod %{
      "ROLE" => "web",
      "DATABASE_URL" => "ecto://user:pass@localhost/db",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "PHX_HOST" => "stats.example.org",
      "KICK_API_URL" => "http://kick.test",
      "KICK_ID_URL" => "http://kick.test",
      "KICK_V2_URL" => "http://kick.test/api/v2",
      "PUSHER_URL" => "ws://kick.test/app/key",
      "KICK_CLIENT_ID" => "id",
      "KICK_CLIENT_SECRET" => "secret",
      "AMQP_URL" => "amqp://user:pass@localhost:5672",
      "PHX_URL_SCHEME" => nil,
      "PHX_URL_PORT" => nil
    }

    defp prod_url(overrides) do
      env = Map.merge(@prod, overrides)
      saved = Map.new(env, fn {name, _} -> {name, System.get_env(name)} end)

      try do
        for {name, value} <- env,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

        Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :prod)
        |> get_in([:kick_tracker, KickTrackerWeb.Endpoint, :url])
      after
        for {name, value} <- saved,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
      end
    end

    test "is HTTPS on 443 unless told otherwise" do
      assert prod_url(%{}) == [host: "stats.example.org", port: 443, scheme: "https"]
    end

    test "takes a scheme and port where the site is served otherwise (the sandbox)" do
      assert prod_url(%{
               "PHX_HOST" => "localhost",
               "PHX_URL_SCHEME" => "http",
               "PHX_URL_PORT" => "8080"
             }) ==
               [host: "localhost", port: 8080, scheme: "http"]

      assert prod_url(%{"PHX_URL_SCHEME" => "http"})[:port] == 80
    end

    test "refuses a scheme that isn't http or https" do
      assert_raise RuntimeError, ~r/PHX_URL_SCHEME/, fn ->
        prod_url(%{"PHX_URL_SCHEME" => "ftp"})
      end
    end
  end
end
