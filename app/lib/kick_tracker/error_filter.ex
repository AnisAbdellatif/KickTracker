defmodule KickTracker.ErrorFilter do
  @moduledoc """
  Scrubs secrets from an error's context before ErrorTracker stores it
  (`config :error_tracker, filter: ...`, project.md §18.2).

  ErrorTracker keeps a request's params, a LiveView's params and its last
  event's params as they came: a crash during a login or an invitation
  would otherwise store the password and the TOTP code in the database.

    * any value under a key naming a secret (password, code, token,
      secret, …) at any depth becomes `"[FILTERED]"`;
    * an invitation token in a path, URL or query string (the link itself
      is the secret) is replaced the same way.

  Pure, and never raises: ErrorTracker calls it inline, and a filter that
  crashes would lose the error. On an unexpected shape it keeps only the
  keys known to carry nothing secret.
  """

  @behaviour ErrorTracker.Filter

  @filtered "[FILTERED]"

  # Substrings of a key whose value is a secret. The same list filters
  # Phoenix's logs (`:filter_parameters`).
  @secret_keys ~w(password secret token code totp otp cookie authorization signature)

  @doc "The key fragments whose values are secret (also Phoenix's `:filter_parameters`)."
  def secret_keys, do: @secret_keys

  @impl true
  def sanitize(context) when is_map(context) do
    scrub(context)
  rescue
    _ -> Map.take(context, ["live_view.view", "request.method", "request.host"])
  end

  def sanitize(_context), do: %{}

  @doc "Scrubs one value (see the module doc)."
  def scrub(%{__struct__: _} = struct), do: struct

  def scrub(%{} = map) do
    Map.new(map, fn {k, v} ->
      if secret_key?(k), do: {k, @filtered}, else: {k, scrub(v)}
    end)
  end

  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  def scrub(text) when is_binary(text), do: redact_invite(text)
  def scrub(other), do: other

  defp secret_key?(key) when is_binary(key) or is_atom(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@secret_keys, &String.contains?(key, &1))
  end

  defp secret_key?(_), do: false

  @doc """
  Replaces an invitation token in a path, URL or query string
  (`/admin/invite/<token>` or `?token=<token>`). Pure.
  """
  @spec redact_invite(String.t()) :: String.t()
  def redact_invite(text) do
    text
    |> String.replace(~r{/admin/invite/[^/?#\s"]+}, "/admin/invite/" <> @filtered)
    |> String.replace(
      ~r{((?:^|[?&;])[^=&;\s]*(?:token|code|password)[^=&;\s]*=)[^&;#\s"]*}i,
      "\\1" <> @filtered
    )
  end
end
