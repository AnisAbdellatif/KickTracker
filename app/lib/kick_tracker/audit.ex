defmodule KickTracker.Audit do
  @moduledoc """
  The admin audit log (project.md §13.8): every admin action, who and
  when. Append-only.
  """

  import Ecto.Query

  alias KickTracker.Admins.Admin
  alias KickTracker.Repo

  @doc "Records an action. `admin` is nil for actions from the command line."
  @spec log(Admin.t() | nil, String.t(), String.t() | nil, map()) :: :ok
  def log(admin, action, target \\ nil, details \\ %{}) do
    Repo.insert_all("admin_audit_log", [
      %{
        admin_id: admin && admin.id,
        admin_email: admin && admin.email,
        action: action,
        target: target,
        details: details,
        at: DateTime.utc_now()
      }
    ])

    :ok
  end

  @doc "The latest entries, newest first."
  @spec recent(pos_integer(), keyword()) :: [map()]
  def recent(limit \\ 100, opts \\ []) do
    query =
      from l in "admin_audit_log",
        order_by: [desc: l.at, desc: l.id],
        limit: ^limit,
        select: %{
          id: l.id,
          admin_email: l.admin_email,
          action: l.action,
          target: l.target,
          details: l.details,
          at: l.at
        }

    query =
      case opts[:action] do
        nil -> query
        action -> where(query, [l], l.action == ^action)
      end

    Repo.all(query)
  end
end
