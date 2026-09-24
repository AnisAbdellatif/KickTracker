defmodule KickTracker.Release do
  @moduledoc """
  Tasks for a release, where Mix isn't available:

      bin/kick_tracker eval "KickTracker.Release.migrate()"
      bin/kick_tracker eval 'KickTracker.Release.invite("someone@example.com")'

  Migrations run as their own step before a deploy (project.md §19.1), and
  follow expand-then-contract (§15.3).
  """

  @app :kick_tracker

  @doc "Runs pending migrations."
  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Invites an admin from the command line (the first one, or when every
  admin is locked out) and prints the link to send them.
  """
  def invite(email) do
    Application.load(@app)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(KickTracker.Repo, fn _repo ->
        IO.puts(invite_link(email))
      end)

    :ok
  end

  @doc false
  def invite_link(email) do
    case KickTracker.Admins.invite(nil, email) do
      {:ok, token} ->
        KickTracker.Audit.log(nil, "admin.invite", String.trim(email), %{"from" => "command line"})

        # From configuration, not the endpoint: it isn't running here.
        config = Application.get_env(@app, KickTrackerWeb.Endpoint, [])
        base = url_base(config[:url] || [], get_in(config, [:http, :port]))

        "Invitation for #{String.trim(email)} (valid 7 days, once):\n#{base}/admin/invite/#{token}"

      {:error, changeset} ->
        "Could not invite: #{inspect(changeset.errors)}"
    end
  end

  defp url_base(url, http_port) do
    scheme = Keyword.get(url, :scheme, "http")
    host = Keyword.get(url, :host, "localhost")
    port = Keyword.get(url, :port, http_port)

    default? = {scheme, port} in [{"https", 443}, {"http", 80}] or is_nil(port)
    "#{scheme}://#{host}#{if default?, do: "", else: ":#{port}"}"
  end
end
