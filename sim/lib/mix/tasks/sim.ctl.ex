defmodule Mix.Tasks.Sim.Ctl do
  @shortdoc "Drives a running fake Kick (start streams, send events, inject faults)"

  @moduledoc """
  Talks to the control API of a running `mix sim`.

      mix sim.ctl status
      mix sim.ctl clock --advance 2h            # also: --at 2026-01-05T20:00:00Z, --speed 60
      mix sim.ctl live <channel> --minutes 90
      mix sim.ctl offline <channel>
      mix sim.ctl title <channel> "New title"
      mix sim.ctl category <channel> 15
      mix sim.ctl event <channel> follow         # sub, resub --months 12, gift --count 20 [--anonymous],
                                                 # kicks --amount 500, ban [--permanent], redemption
      mix sim.ctl chat <channel> "hello chat"
      mix sim.ctl webhooks http://localhost:4040/
      mix sim.ctl webhooks --drop-next 3
      mix sim.ctl faults --drop 0.1 --duplicate 0.05 --pusher-disconnect 30
      mix sim.ctl faults --clear
      mix sim.ctl disconnect                     # close every Pusher socket (4200)
      mix sim.ctl expire-tokens

  `--url` points at another simulator (default `http://127.0.0.1:4050`).
  Durations take `90` (seconds), `15m`, `2h` or `1d`.
  """

  use Mix.Task

  @switches [
    url: :string,
    at: :string,
    speed: :float,
    advance: :string,
    minutes: :integer,
    user: :integer,
    count: :integer,
    amount: :integer,
    months: :integer,
    anonymous: :boolean,
    permanent: :boolean,
    sender: :integer,
    drop_next: :integer,
    drop: :float,
    duplicate: :float,
    pusher_disconnect: :float,
    clear: :boolean
  ]

  @impl true
  def run(args) do
    {opts, words} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    case request(words, opts) do
      {:ok, {method, path, body}} ->
        url = Keyword.get(opts, :url, "http://127.0.0.1:4050") <> "/_sim" <> path
        send_request(method, url, body, words)

      {:error, message} ->
        Mix.raise(message <> "\n\n" <> usage())
    end
  end

  @doc """
  Turns command-line words and options into a control API request. Pure,
  so the whole command language is tested without a running simulator.
  """
  @spec request([String.t()], keyword()) ::
          {:ok, {atom(), String.t(), map() | nil}} | {:error, String.t()}
  def request(["status"], _opts), do: {:ok, {:get, "/state", nil}}

  def request(["clock"], opts) do
    with {:ok, advance} <- optional_duration(opts[:advance]) do
      body =
        %{"at" => opts[:at], "speed" => opts[:speed], "advance_s" => advance}
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      if body == %{}, do: {:ok, {:get, "/state", nil}}, else: {:ok, {:put, "/clock", body}}
    end
  end

  def request(["live", slug], opts),
    do: {:ok, {:post, "/channels/#{enc(slug)}/live", compact(%{"minutes" => opts[:minutes]})}}

  def request(["offline", slug], _opts), do: {:ok, {:post, "/channels/#{enc(slug)}/offline", %{}}}

  def request(["title", slug, title], _opts),
    do: {:ok, {:post, "/channels/#{enc(slug)}/metadata", %{"title" => title}}}

  def request(["category", slug, id], _opts) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, {:post, "/channels/#{enc(slug)}/metadata", %{"category_id" => n}}}
      _ -> {:error, "category takes a numeric category id, got #{inspect(id)}"}
    end
  end

  def request(["event", slug, type], opts) do
    body =
      compact(%{
        "type" => type,
        "user_id" => opts[:user],
        "count" => opts[:count],
        "amount" => opts[:amount],
        "months" => opts[:months],
        "anonymous" => opts[:anonymous],
        "permanent" => opts[:permanent]
      })

    {:ok, {:post, "/channels/#{enc(slug)}/events", body}}
  end

  def request(["chat", slug, content], opts),
    do:
      {:ok,
       {:post, "/channels/#{enc(slug)}/chat",
        compact(%{"content" => content, "sender_id" => opts[:sender]})}}

  def request(["webhooks"], opts) do
    case compact(%{"drop_next" => opts[:drop_next]}) do
      empty when empty == %{} -> {:ok, {:get, "/webhooks", nil}}
      body -> {:ok, {:put, "/webhooks", body}}
    end
  end

  # The webhook URL is a word, not `--url`, which is the simulator's own address.
  def request(["webhooks", webhook_url], opts),
    do:
      {:ok,
       {:put, "/webhooks", compact(%{"url" => webhook_url, "drop_next" => opts[:drop_next]})}}

  def request(["faults"], opts) do
    if opts[:clear] do
      {:ok, {:put, "/faults", %{}}}
    else
      {:ok,
       {:put, "/faults",
        compact(%{
          "drop_webhooks" => opts[:drop],
          "duplicate_webhooks" => opts[:duplicate],
          "pusher_disconnect_after_s" => opts[:pusher_disconnect]
        })}}
    end
  end

  def request(["disconnect"], _opts), do: {:ok, {:post, "/pusher/disconnect", %{}}}
  def request(["expire-tokens"], _opts), do: {:ok, {:post, "/tokens/expire", %{}}}
  def request([], _opts), do: {:error, "which command?"}
  def request(words, _opts), do: {:error, "unknown command: #{Enum.join(words, " ")}"}

  @doc "Parses `90`, `15m`, `2h` or `1d` into seconds."
  @spec duration(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def duration(text) do
    case Regex.run(~r/^(\d+)([smhd]?)$/, text) do
      [_, n, unit] ->
        {:ok,
         String.to_integer(n) *
           Map.fetch!(%{"" => 1, "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}, unit)}

      nil ->
        {:error, "a duration looks like 90, 15m, 2h or 1d, got #{inspect(text)}"}
    end
  end

  defp optional_duration(nil), do: {:ok, nil}
  defp optional_duration(text), do: duration(text)

  defp send_request(method, url, body, words) do
    options = [method: method, url: url, retry: false, receive_timeout: 30_000]
    options = if body, do: Keyword.put(options, :json, body), else: options

    case Req.request(options) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        print(words, response)

      {:ok, %{status: status, body: response}} ->
        Mix.raise("the simulator refused (HTTP #{status}): #{error_text(response)}")

      {:error, reason} ->
        Mix.raise("no simulator at #{url}: #{Exception.message(reason)} (is `mix sim` running?)")
    end
  end

  defp print(["status" | _], state), do: print_state(state)
  defp print(["clock"], %{"channels" => _} = state), do: print_state(state)
  defp print(_words, response), do: Mix.shell().info(Jason.encode!(response, pretty: true))

  defp print_state(state) do
    Mix.shell().info("simulated now #{state["now"]} (#{state["speed"]}x)")

    for c <- state["channels"] do
      line =
        if c["live"],
          do:
            "live since #{c["started_at"]}, #{c["viewers"]} viewers, #{c["category"]}: #{c["title"]}",
          else: "offline, next #{c["next_start"] || "never"}"

      Mix.shell().info("  #{String.pad_trailing(c["slug"], 16)} #{line}")
    end

    w = state["webhooks"]

    Mix.shell().info(
      "webhooks -> #{w["url"] || "(nowhere)"}: #{w["sent"]} sent, #{w["dropped"]} dropped, #{w["subscriptions"]} subscriptions"
    )

    Mix.shell().info(
      "pusher: #{state["pusher"]["sockets"]} sockets; faults: #{inspect(state["faults"])}"
    )
  end

  defp error_text(%{"error" => error}), do: error
  defp error_text(other), do: inspect(other)

  defp compact(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
  defp enc(slug), do: URI.encode(slug, &URI.char_unreserved?/1)

  defp usage, do: "see: mix help sim.ctl"
end
