defmodule Mix.Tasks.Sim.CtlTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sim.Ctl
  alias Sim.{Clock, Instance, Scenario, Server}

  describe "the command language" do
    test "each command becomes the right request" do
      assert Ctl.request(["status"], []) == {:ok, {:get, "/state", nil}}

      assert Ctl.request(["live", "somestreamer"], minutes: 90) ==
               {:ok, {:post, "/channels/somestreamer/live", %{"minutes" => 90}}}

      assert Ctl.request(["live", "somestreamer"], []) ==
               {:ok, {:post, "/channels/somestreamer/live", %{}}}

      assert Ctl.request(["offline", "somestreamer"], []) ==
               {:ok, {:post, "/channels/somestreamer/offline", %{}}}

      assert Ctl.request(["title", "somestreamer", "Hello"], []) ==
               {:ok, {:post, "/channels/somestreamer/metadata", %{"title" => "Hello"}}}

      assert Ctl.request(["category", "somestreamer", "15"], []) ==
               {:ok, {:post, "/channels/somestreamer/metadata", %{"category_id" => 15}}}

      assert Ctl.request(["event", "somestreamer", "gift"], count: 20, anonymous: true) ==
               {:ok,
                {:post, "/channels/somestreamer/events",
                 %{"type" => "gift", "count" => 20, "anonymous" => true}}}

      assert Ctl.request(["chat", "somestreamer", "hi"], sender: 7) ==
               {:ok,
                {:post, "/channels/somestreamer/chat", %{"content" => "hi", "sender_id" => 7}}}

      assert Ctl.request(["webhooks"], []) == {:ok, {:get, "/webhooks", nil}}

      assert Ctl.request(["webhooks"], drop_next: 3) ==
               {:ok, {:put, "/webhooks", %{"drop_next" => 3}}}

      assert Ctl.request(["webhooks", "http://localhost:4040/"], []) ==
               {:ok, {:put, "/webhooks", %{"url" => "http://localhost:4040/"}}}

      assert Ctl.request(["faults"], drop: 0.1) ==
               {:ok, {:put, "/faults", %{"drop_webhooks" => 0.1}}}

      assert Ctl.request(["faults"], clear: true) == {:ok, {:put, "/faults", %{}}}
      assert Ctl.request(["disconnect"], []) == {:ok, {:post, "/pusher/disconnect", %{}}}
      assert Ctl.request(["expire-tokens"], []) == {:ok, {:post, "/tokens/expire", %{}}}
    end

    test "the clock takes durations, a time, or a speed; nothing means show the state" do
      assert Ctl.request(["clock"], advance: "2h") ==
               {:ok, {:put, "/clock", %{"advance_s" => 7_200}}}

      assert Ctl.request(["clock"], speed: 60.0) == {:ok, {:put, "/clock", %{"speed" => 60.0}}}
      assert Ctl.request(["clock"], []) == {:ok, {:get, "/state", nil}}
      assert {:error, _} = Ctl.request(["clock"], advance: "soon")
    end

    test "durations" do
      assert Ctl.duration("90") == {:ok, 90}
      assert Ctl.duration("15m") == {:ok, 900}
      assert Ctl.duration("2h") == {:ok, 7_200}
      assert Ctl.duration("1d") == {:ok, 86_400}
      assert {:error, _} = Ctl.duration("1w")
    end

    test "slugs are escaped in paths" do
      assert {:ok, {:post, "/channels/a%2Fb/offline", _}} = Ctl.request(["offline", "a/b"], [])
    end

    test "nonsense is refused with a message, not sent" do
      assert {:error, "which command?"} = Ctl.request([], [])
      assert {:error, "unknown command: dance"} = Ctl.request(["dance"], [])
      assert {:error, _} = Ctl.request(["category", "somestreamer", "chatting"], [])
    end
  end

  describe "against a running simulator" do
    setup do
      scenario =
        Scenario.new(
          channels: [
            [slug: "somestreamer", schedule: %{days: [6], start_hour: 14, duration_min: 60}]
          ]
        )

      start_supervised!(
        {Instance,
         scenario: scenario,
         clock: Clock.new(sim_start: ~U[2026-01-05 10:00:00Z]),
         port: 0,
         tick_ms: 0}
      )

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      %{url: Instance.base_url()}
    end

    defp output do
      Stream.repeatedly(fn ->
        receive do
          {:mix_shell, :info, [line]} -> line
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.join("\n")
    end

    test "status, going live, and going offline", %{url: url} do
      Ctl.run(["status", "--url", url])
      assert output() =~ ~r/somestreamer\s+offline, next 2026-01-10T14:00:00Z/

      Ctl.run(["live", "somestreamer", "--minutes", "30", "--url", url])
      assert output() =~ "livestream.status.updated"
      assert Sim.Schedule.live?(Scenario.channel(Server.scenario(), "somestreamer"), Server.now())

      Ctl.run(["status", "--url", url])
      assert output() =~ ~r/somestreamer\s+live since/

      Ctl.run(["offline", "somestreamer", "--url", url])
      refute Sim.Schedule.live?(Scenario.channel(Server.scenario(), "somestreamer"), Server.now())
    end

    test "a refused command fails loudly with the simulator's reason", %{url: url} do
      assert_raise Mix.Error, ~r/HTTP 409.*not_live/, fn ->
        Ctl.run(["offline", "somestreamer", "--url", url])
      end
    end

    test "no simulator is a clear error, not a stack trace" do
      assert_raise Mix.Error, ~r/is `mix sim` running/, fn ->
        Ctl.run(["status", "--url", "http://127.0.0.1:1"])
      end
    end
  end
end
