defmodule KickTracker.Kick.HTTP do
  @moduledoc """
  Sends a request kicksdk built, with Req, the way every request to Kick
  goes out: with our User-Agent (project.md §18.3), a timeout, and the
  body left as text for kicksdk's parser. Nothing here knows Kick; what
  to ask and how to read the answer is kicksdk's (KICK.md).
  """

  @doc """
  The answer's status and body, or Req's error. `opts` go to Req (a retry
  policy, a shorter timeout); by default nothing is retried.
  """
  @spec send(map(), keyword()) :: {:ok, pos_integer(), binary()} | {:error, Exception.t()}
  def send(%{"method" => method, "url" => url, "headers" => headers} = request, opts \\ []) do
    [
      method: method(method),
      url: url,
      headers: headers ++ KickTracker.Kick.UserAgent.headers(),
      body: request["body"],
      decode_body: false,
      receive_timeout: 15_000,
      retry: false
    ]
    |> Keyword.merge(opts)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Reads an answer with one of kicksdk's parsers (`parser.(status, body)`).
  kicksdk reads text: a body that isn't UTF-8 is no answer it knows.
  """
  @spec parse((pos_integer(), String.t() -> result), pos_integer(), binary()) ::
          result | {:error, term()}
        when result: {:ok, term()} | {:error, term()}
  def parse(parser, status, body) do
    cond do
      String.valid?(body) -> parser.(status, body)
      status in 200..299 -> {:error, {:json, "not UTF-8"}}
      true -> {:error, {:status, status, ""}}
    end
  end

  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method("DELETE"), do: :delete
end
