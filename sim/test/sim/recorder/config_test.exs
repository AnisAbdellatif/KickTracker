defmodule Sim.Recorder.ConfigTest do
  use ExUnit.Case, async: true

  alias Sim.Recorder.Config

  test "parse_env/1 reads KEY=value lines, skipping blanks and comments, stripping quotes" do
    contents = """
    # comment
    KICK_CLIENT_ID=abc

    KICK_CLIENT_SECRET = "s=e=c"
    KICK_CONTACT='me@example.com'
    not a pair
    """

    assert Config.parse_env(contents) == [
             {"KICK_CLIENT_ID", "abc"},
             {"KICK_CLIENT_SECRET", "s=e=c"},
             {"KICK_CONTACT", "me@example.com"}
           ]
  end

  test "the User-Agent names us, with a contact when one is set" do
    assert Config.user_agent(%Config{contact: nil}) == "kick-tracker-recorder/0.1"

    assert Config.user_agent(%Config{contact: "me@example.com"}) ==
             "kick-tracker-recorder/0.1 (+me@example.com)"
  end
end
