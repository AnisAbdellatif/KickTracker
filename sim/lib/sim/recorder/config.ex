defmodule Sim.Recorder.Config do
  @moduledoc """
  Where the recorder points and with which credentials.

  Everything comes from the environment (AGENTS.md §6), with Kick's real
  endpoints as defaults since the recorder's whole purpose is to talk to the
  real Kick. A `sim/.env` file, if present, is loaded first; variables already
  set in the environment win.
  """

  @defaults %{
    "KICK_API_URL" => "https://api.kick.com",
    "KICK_ID_URL" => "https://id.kick.com",
    "KICK_V2_URL" => "https://kick.com/api/v2",
    "PUSHER_URL" =>
      "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false"
  }

  defstruct [:api_url, :id_url, :v2_url, :pusher_url, :client_id, :client_secret, :contact]

  @type t :: %__MODULE__{}

  @doc "Reads the configuration. Credentials may be nil; `require_credentials!/1` checks them."
  @spec load(Path.t()) :: t()
  def load(env_file \\ ".env") do
    load_env_file(env_file)

    %__MODULE__{
      api_url: get("KICK_API_URL"),
      id_url: get("KICK_ID_URL"),
      v2_url: get("KICK_V2_URL"),
      pusher_url: get("PUSHER_URL"),
      client_id: System.get_env("KICK_CLIENT_ID"),
      client_secret: System.get_env("KICK_CLIENT_SECRET"),
      contact: System.get_env("KICK_CONTACT")
    }
  end

  @spec require_credentials!(t()) :: t()
  def require_credentials!(%__MODULE__{client_id: id, client_secret: secret} = config)
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    config
  end

  def require_credentials!(_config) do
    Mix.raise("KICK_CLIENT_ID and KICK_CLIENT_SECRET must be set (environment or sim/.env)")
  end

  @doc "The User-Agent sent on every request, identifying us to Kick."
  @spec user_agent(t()) :: String.t()
  def user_agent(%__MODULE__{contact: nil}), do: "kick-tracker-recorder/0.1"
  def user_agent(%__MODULE__{contact: contact}), do: "kick-tracker-recorder/0.1 (+#{contact})"

  defp get(name), do: System.get_env(name) || Map.fetch!(@defaults, name)

  # KEY=value lines; blank lines and # comments skipped; optional quotes
  # stripped. Existing environment variables are never overwritten.
  defp load_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        for {key, value} <- parse_env(contents), System.get_env(key) == nil do
          System.put_env(key, value)
        end

      {:error, _} ->
        :ok
    end
  end

  @doc false
  @spec parse_env(String.t()) :: [{String.t(), String.t()}]
  def parse_env(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{String.trim(key), unquote_value(String.trim(value))}]
        _ -> []
      end
    end)
  end

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value
  end

  defp unquote_value(value), do: value
end
