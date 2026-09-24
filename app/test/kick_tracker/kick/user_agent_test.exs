defmodule KickTracker.Kick.UserAgentTest do
  use ExUnit.Case, async: false

  alias KickTracker.Kick.UserAgent

  setup do
    on_exit(fn ->
      Application.delete_env(:kick_tracker, :kick_user_agent)
      Application.delete_env(:kick_tracker, :contact_email)
    end)
  end

  test "names us and says how to reach us" do
    Application.put_env(:kick_tracker, :contact_email, "someone@example.com")

    assert UserAgent.value() =~
             ~r{^Stream-Tracker/\S+ \(\+https://localhost; someone@example\.com\)$}
  end

  test "an explicit value wins" do
    Application.put_env(:kick_tracker, :kick_user_agent, "custom/1.0")
    assert UserAgent.headers() == [{"user-agent", "custom/1.0"}]
  end
end
