ExUnit.start()

# Key pairs are generated once, here, before any test runs: generated
# lazily, two async tests could each make one and sign with the loser.
for name <- [:default, :other], do: KickTracker.TestKick.pair(name)
Ecto.Adapters.SQL.Sandbox.mode(KickTracker.Repo, :manual)
