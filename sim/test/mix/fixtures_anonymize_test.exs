defmodule Mix.Tasks.Fixtures.AnonymizeTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp recording(dir, run, source, name, body) do
    path = Path.join([dir, "recordings", run, source])
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, name),
      Jason.encode!(%{
        "kind" => "http",
        "request" => %{
          "method" => "GET",
          "url" => "https://kick.com/api/v2/channels/somestreamer"
        },
        "response" => %{"status" => 200, "headers" => [], "body" => body}
      })
    )
  end

  defp anonymize(dir) do
    File.cd!(dir, fn ->
      Mix.Tasks.Fixtures.Anonymize.run(["--out", "fixtures", "--map", "map.json"])
    end)

    dir |> Path.join("fixtures/public_api/*.json") |> Path.wildcard()
  end

  test "two runs of the same task don't overwrite each other's fixtures", %{tmp_dir: dir} do
    recording(dir, "20260924T010000Z-api", "public_api", "0000-channels.json", ~s({"n":1}))
    recording(dir, "20260924T020000Z-api", "public_api", "0000-channels.json", ~s({"n":2}))

    files = anonymize(dir)

    assert length(files) == 2

    assert files
           |> Enum.map(&(&1 |> File.read!() |> Jason.decode!() |> get_in(["response", "body"])))
           |> Enum.sort() == [~s({"n":1}), ~s({"n":2})]
  end

  test "the run name is part of the fixture name, so provenance is visible", %{tmp_dir: dir} do
    recording(dir, "20260924T010000Z-api", "public_api", "0000-channels.json", ~s({"n":1}))

    assert [path] = anonymize(dir)
    assert Path.basename(path) == "20260924T010000Z-api__0000-channels.json"
  end
end
