defmodule Mix.Tasks.Fixtures.Anonymize do
  @shortdoc "Turns raw recordings into anonymized fixtures"

  @moduledoc """
  Reads raw recordings from `sim/recordings/` (git-ignored, real data) and
  writes anonymized copies to `fixtures/` (committed).

      mix fixtures.anonymize                       # every run
      mix fixtures.anonymize --run recordings/20260924T180000Z-api

  The real→fake mapping is kept in `sim/recordings/.anonymizer-map.json` so
  the same person gets the same pseudonym across runs. That file contains
  real values and must stay out of git (it does: the folder is ignored).

  At the end it prints every field path whose string values were kept
  without a rule (paths only, never values). **Review that list before
  committing fixtures**: a path there that holds personal data needs a rule
  in `Sim.Fixtures.Anonymizer`.

  Then it runs `Sim.Fixtures.LeakCheck`: every real name, chat text and id
  found in the raw files is searched for in the output. If any is found the
  task fails (field paths shown, never values) and the fixtures must not be
  committed.
  """

  use Mix.Task

  alias Sim.Fixtures.{Anonymizer, LeakCheck, Recording}

  @map_file "recordings/.anonymizer-map.json"

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [run: :keep, out: :string, map: :string])
    out = Keyword.get(opts, :out, "../fixtures")
    map_file = Keyword.get(opts, :map, @map_file)

    runs =
      case Keyword.get_values(opts, :run) do
        [] -> Path.wildcard("recordings/*") |> Enum.filter(&File.dir?/1) |> Enum.sort()
        given -> given
      end

    if runs == [], do: Mix.raise("no recordings found in sim/recordings/")

    state = Anonymizer.new(load_map(map_file))

    {count, state, sensitive, written} =
      Enum.reduce(runs, {0, state, %{}, []}, fn run, acc ->
        run
        |> Path.join("**/*.{json,jsonl}")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) == "summary.json"))
        |> Enum.reduce(acc, fn path, {n, state, sensitive, written} ->
          {raw, docs, state} = file(path, run, out, state)
          sensitive = Enum.reduce(raw, sensitive, &Map.merge(LeakCheck.sensitive(&1), &2))
          {n + 1, state, sensitive, docs ++ written}
        end)
      end)

    File.write!(map_file, Jason.encode_to_iodata!(Anonymizer.to_saved(state), pretty: true))
    Mix.shell().info("anonymized #{count} files into #{out}")
    report(state.unknown)
    leak_check(sensitive, written)
  end

  defp leak_check(sensitive, written) do
    case LeakCheck.leaks(sensitive, written) do
      leaks when map_size(leaks) == 0 ->
        Mix.shell().info(
          "leak check: none of #{map_size(sensitive)} real values found in the output"
        )

      leaks ->
        Mix.shell().error(
          "\nLEAK CHECK FAILED: real values found in the output. Do not commit fixtures/."
        )

        for {path, count} <- Enum.sort(leaks) do
          Mix.shell().error("  from raw field #{path}  (#{count} values)")
        end

        Mix.raise("fix the anonymizer rules (with a test), then run again")
    end
  end

  defp file(path, run, out, state) do
    source = path |> Path.dirname() |> Path.basename()
    # The whole run name, so two runs of the same task can't overwrite each
    # other's files (and each fixture says which run it came from).
    task = Path.basename(run)

    if Path.extname(path) == ".jsonl" do
      # Pusher files are named after the channel slug.
      {name, state} = Anonymizer.name(Path.basename(path, ".jsonl"), state)

      {lines, state} =
        path
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map_reduce(state, &Recording.pusher_line/2)

      target = Path.join([out, source, "#{task}__#{name}.jsonl"])
      write(target, Enum.map(lines, &[Jason.encode!(&1), ?\n]))
      raw = path |> File.stream!() |> Enum.map(&Jason.decode!/1)
      # The raw file name is the channel slug, so it's a sensitive value too.
      slug = %{"slug" => Path.basename(path, ".jsonl")}
      {[slug | raw], [Path.basename(target) | lines], state}
    else
      raw = path |> File.read!() |> Jason.decode!()
      {rec, state} = Recording.anonymize(raw, state)
      target = Path.join([out, source, "#{task}__#{Path.basename(path)}"])
      write(target, Jason.encode_to_iodata!(rec, pretty: true))
      {[raw], [Path.basename(target), rec], state}
    end
  end

  defp write(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp load_map(map_file) do
    case File.read(map_file) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> %{}
    end
  end

  defp report(unknown) when map_size(unknown) == 0 do
    Mix.shell().info("no unreviewed string fields")
  end

  defp report(unknown) do
    Mix.shell().info("\nstring fields kept without a rule (review before committing fixtures):")

    for {path, count} <- Enum.sort(unknown) do
      Mix.shell().info("  #{path}  (#{count})")
    end
  end
end
