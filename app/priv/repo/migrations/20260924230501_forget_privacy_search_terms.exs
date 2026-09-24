defmodule KickTracker.Repo.Migrations.ForgetPrivacySearchTerms do
  use Ecto.Migration

  # The privacy page used to log what was searched for (a username or a
  # Kick id, found or not) in the audit log, where a deletion never
  # reached it. Searches are now logged without the term; this forgets
  # the terms already logged. Data only: old and new code both work with
  # it. Not reversible (the terms are gone on purpose).
  def up do
    execute("UPDATE admin_audit_log SET target = NULL WHERE action = 'privacy.find'")
  end

  def down, do: :ok
end
