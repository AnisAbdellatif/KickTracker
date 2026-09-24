defmodule Sim.Recorder.StoreTest do
  use ExUnit.Case, async: true

  alias Sim.Recorder.Store

  describe "redact/1" do
    test "secret headers are redacted in list and map form, whatever their case" do
      rec = %{
        "request" => %{
          "headers" => [["Authorization", "Bearer abc"], ["accept", "application/json"]]
        },
        "response" => %{
          "headers" => %{"Set-Cookie" => "x=1", "content-type" => "application/json"}
        }
      }

      redacted = Store.redact(rec)

      assert redacted["request"]["headers"] == [
               ["Authorization", "[redacted]"],
               ["accept", "application/json"]
             ]

      assert redacted["response"]["headers"] == %{
               "Set-Cookie" => "[redacted]",
               "content-type" => "application/json"
             }
    end

    test "tokens and playback_url inside JSON bodies are redacted" do
      body =
        ~s({"access_token":"secret","expires_in":3600,"livestream":{"playback_url":"https://x/y?token=z"}})

      redacted =
        Store.redact(%{"response" => %{"body" => body}})["response"]["body"] |> Jason.decode!()

      assert redacted["access_token"] == "[redacted]"
      assert redacted["expires_in"] == 3600
      assert redacted["livestream"]["playback_url"] == "[redacted]"
    end

    test "bodies without secrets are kept byte for byte (webhook signatures depend on it)" do
      body = ~s({"b": 1,  "a":[ 2 ]}\n)
      assert Store.redact(%{"request" => %{"body" => body}})["request"]["body"] == body
    end

    test "non-JSON bodies are kept as they are" do
      assert Store.redact(%{"body" => "<html>access_token</html>"})["body"] ==
               "<html>access_token</html>"
    end
  end

  @tag :tmp_dir
  test "write/4 numbers files per source and never writes a secret", %{tmp_dir: dir} do
    p1 =
      Store.write(dir, "id", "token", %{"response" => %{"body" => ~s({"access_token":"s3cret"})}})

    p2 = Store.write(dir, "id", "token", %{"x" => 1})

    assert Path.basename(p1) == "0000-token.json"
    assert Path.basename(p2) == "0001-token.json"
    refute File.read!(p1) =~ "s3cret"
  end

  @tag :tmp_dir
  test "append_line/4 writes one JSON document per line", %{tmp_dir: dir} do
    Store.append_line(dir, "pusher", "chan", %{"n" => 1})
    Store.append_line(dir, "pusher", "chan", %{"n" => 2})

    lines =
      dir |> Path.join("pusher/chan.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert Enum.map(lines, &Jason.decode!/1) == [%{"n" => 1}, %{"n" => 2}]
  end
end
