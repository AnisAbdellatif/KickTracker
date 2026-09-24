defmodule KickTrackerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KickTrackerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint KickTrackerWeb.Endpoint

      use KickTrackerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KickTrackerWeb.ConnCase
    end
  end

  setup tags do
    KickTracker.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Setup: a logged-in admin (`conn`, `admin`)."
  def log_in_admin(%{conn: conn}) do
    {admin, _password, _secret} = KickTracker.Fixtures.admin!()
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  @doc "Logs an admin in on a test conn."
  def log_in_admin(conn, admin) do
    token = KickTracker.Admins.create_session_token(admin)

    Plug.Test.init_test_session(conn,
      admin_token: token,
      live_socket_id: KickTracker.Admins.live_socket_id(token)
    )
  end
end
