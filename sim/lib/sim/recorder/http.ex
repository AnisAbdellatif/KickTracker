defmodule Sim.Recorder.HTTP do
  @moduledoc """
  Makes one request to Kick and returns it as a recording: the request (URL,
  method, headers) and the response exactly as received (status, all headers,
  raw body). No retries: a 429 or 5xx is itself worth recording.
  """

  alias Sim.Recorder.Config

  @type recording :: map()

  @spec request(Config.t(), atom(), String.t(), keyword()) ::
          {:ok, recording()} | {:error, term()}
  def request(config, method, url, opts \\ []) do
    headers =
      [{"user-agent", Config.user_agent(config)}, {"accept", "application/json"}] ++
        auth_header(opts[:token]) ++ Keyword.get(opts, :headers, [])

    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        params: Keyword.get(opts, :params, []),
        decode_body: false,
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      ] ++ Keyword.take(opts, [:form, :json])

    started = System.monotonic_time(:millisecond)
    recorded_at = now()

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = resp} ->
        {:ok,
         %{
           "kind" => "http",
           "recorded_at" => recorded_at,
           "elapsed_ms" => System.monotonic_time(:millisecond) - started,
           "request" => %{
             "method" => method |> to_string() |> String.upcase(),
             "url" => url,
             "params" =>
               Map.new(Keyword.get(opts, :params, []), fn {k, v} -> {to_string(k), v} end),
             "headers" => Enum.map(headers, fn {k, v} -> [k, v] end),
             "json" => opts[:json]
           },
           "response" => %{
             "status" => resp.status,
             "headers" => flatten_headers(resp.headers),
             "body" => IO.iodata_to_binary(resp.body)
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Decodes a recording's JSON body, or returns nil."
  @spec json(recording()) :: term() | nil
  def json(%{"response" => %{"body" => body}}) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  @spec status(recording()) :: integer()
  def status(%{"response" => %{"status" => status}}), do: status

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp auth_header(nil), do: []
  defp auth_header(token), do: [{"authorization", "Bearer " <> token}]

  defp flatten_headers(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: [name, value]
  end
end
