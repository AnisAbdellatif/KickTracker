defmodule KickTracker.Kick.Endpoints do
  @moduledoc """
  Where Kick is, in the form kicksdk takes it (the last argument of every
  request builder): built from our configuration (`KICK_API_URL`,
  `KICK_ID_URL`, `KICK_V2_URL`, `KICK_REALTIME_URL`; AGENTS.md §6), so the
  same code talks to the real Kick or to the fake one.

  The one place our settings and kicksdk's names meet: our API URL stops
  before `/public/v1` (kicksdk's `api` includes it), and our v2 URL is the
  website's `/api/v2` (kicksdk's `website` is the site itself).
  """

  # Never left out: kicksdk would fill a missing one with the real Kick's.
  # A request to this fails (`.invalid` never resolves), a gap like any other.
  @unset "http://not-configured.invalid"

  @doc """
  The endpoints, from the `:kick` configuration with `overrides` on top
  (a process given its own URL, in tests).
  """
  @spec get(keyword()) :: %{
          api: String.t(),
          id: String.t(),
          website: String.t(),
          realtime: String.t()
        }
  def get(overrides \\ []) do
    kick = Keyword.merge(Application.get_env(:kick_tracker, :kick, []), overrides)

    %{
      api: url(kick, :api_url) <> "/public/v1",
      id: url(kick, :id_url),
      website:
        kick |> url(:v2_url) |> String.trim_trailing("/") |> String.replace_suffix("/api/v2", ""),
      realtime: url(kick, :realtime_url)
    }
  end

  defp url(kick, key) do
    case kick[key] do
      url when is_binary(url) and url != "" -> url
      _ -> @unset
    end
  end
end
