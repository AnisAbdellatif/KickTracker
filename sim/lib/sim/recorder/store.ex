defmodule Sim.Recorder.Store do
  @moduledoc """
  Writes raw recordings under `sim/recordings/<run>/` (git-ignored).

  Raw recordings are real, un-anonymized data and never leave this machine;
  `mix fixtures.anonymize` turns them into `fixtures/`. Secrets are redacted
  here, at write time, so they never reach disk at all: the access token, the
  `Authorization` header, and v2's signed `playback_url` (AGENTS.md §6).
  """

  @redacted "[redacted]"
  @secret_headers ~w(authorization cookie set-cookie)
  @secret_keys ~w(access_token refresh_token client_secret playback_url stream_key
                   publish_token)

  @doc "Creates a new run directory named after the time and the task, and returns it."
  @spec new_run(String.t(), Path.t()) :: Path.t()
  def new_run(task, root \\ "recordings") do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir = Path.join(root, "#{stamp}-#{task}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Writes one recording as pretty JSON at `<run>/<source>/<seq>-<name>.json`.

  Safe to call concurrently, which matters because webhooks arrive
  concurrently: the sequence number is unique and increasing across the
  whole VM (counting the files in the folder was not, and let two
  deliveries overwrite each other), and the file is written under a
  temporary name and renamed into place, so a reader never sees half of it.
  """
  @spec write(Path.t(), String.t(), String.t(), map()) :: Path.t()
  def write(run, source, name, recording) do
    dir = Path.join(run, source)
    File.mkdir_p!(dir)

    seq =
      [:positive, :monotonic]
      |> System.unique_integer()
      |> Integer.to_string()
      |> String.pad_leading(8, "0")

    path = Path.join(dir, "#{seq}-#{safe(name)}.json")
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(redact(recording), pretty: true))
    File.rename!(tmp, path)
    path
  end

  @doc "Appends one JSON line to `<run>/<source>/<name>.jsonl` (for streams like Pusher)."
  @spec append_line(Path.t(), String.t(), String.t(), map()) :: :ok
  def append_line(run, source, name, entry) do
    dir = Path.join(run, source)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{safe(name)}.jsonl"), [Jason.encode!(redact(entry)), ?\n], [
      :append
    ])
  end

  @doc """
  Removes secrets from a recording: secret headers anywhere, secret keys in
  maps, and the same keys inside JSON bodies stored as strings.
  """
  @spec redact(term()) :: term()
  def redact(%{} = map) do
    Map.new(map, fn
      {"headers", headers} -> {"headers", redact_headers(headers)}
      {"body", body} when is_binary(body) -> {"body", redact_json_string(body)}
      {key, _value} when key in @secret_keys -> {key, @redacted}
      {key, value} -> {key, redact(value)}
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other

  defp redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn [name, value] ->
      if String.downcase(name) in @secret_headers, do: [name, @redacted], else: [name, value]
    end)
  end

  defp redact_headers(%{} = headers) do
    Map.new(headers, fn {name, value} ->
      if String.downcase(name) in @secret_headers, do: {name, @redacted}, else: {name, value}
    end)
  end

  # Bodies are kept as raw strings (byte for byte). Only when a body is JSON
  # and holds a secret key is it re-encoded, which is fine: such bodies (token
  # responses, v2) are never signature-checked.
  defp redact_json_string(body) do
    with true <- String.contains?(body, @secret_keys),
         {:ok, decoded} <- Jason.decode(body) do
      decoded |> redact_decoded() |> Jason.encode!()
    else
      _ -> body
    end
  end

  defp redact_decoded(%{} = map) do
    Map.new(map, fn
      {key, _} when key in @secret_keys -> {key, @redacted}
      {key, value} -> {key, redact_decoded(value)}
    end)
  end

  defp redact_decoded(list) when is_list(list), do: Enum.map(list, &redact_decoded/1)
  defp redact_decoded(other), do: other

  defp safe(name), do: String.replace(name, ~r/[^A-Za-z0-9_.-]+/, "_")
end
