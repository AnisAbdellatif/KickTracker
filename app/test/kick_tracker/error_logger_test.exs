defmodule KickTracker.ErrorLoggerTest do
  @moduledoc "A crash in any process reaches ErrorTracker, not only requests and jobs."

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  defmodule Crasher do
    use GenServer
    def init(_), do: {:ok, nil}
    def handle_cast(:crash, _), do: raise(ArgumentError, "somestreamer's process fell over")
  end

  setup do
    Application.put_env(:error_tracker, :enabled, true)
    on_exit(fn -> Application.put_env(:error_tracker, :enabled, false) end)
  end

  test "a GenServer crash is recorded with its exception" do
    {:ok, pid} = GenServer.start(Crasher, nil)
    ref = Process.monitor(pid)
    GenServer.cast(pid, :crash)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    error =
      Enum.find_value(1..100, fn _ ->
        Process.sleep(20)

        Repo.one(
          from e in "error_tracker_errors",
            where: like(e.reason, "%fell over%"),
            select: %{reason: e.reason}
        )
      end)

    assert error.reason =~ "fell over"
  end
end
