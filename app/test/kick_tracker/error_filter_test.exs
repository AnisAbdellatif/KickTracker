defmodule KickTracker.ErrorFilterTest do
  @moduledoc "No password, TOTP code or invitation token reaches ErrorTracker's tables or the logs."

  # Turns ErrorTracker on for a moment: nothing else may run meanwhile.
  use KickTracker.DataCase, async: false

  import Phoenix.ConnTest
  alias KickTracker.ErrorFilter

  @password "correct horse battery staple"
  @code "123456"
  @invite "c2VjcmV0LWludml0YXRpb24tdG9rZW4"

  test "scrubs secret keys at any depth and invitation tokens anywhere" do
    context = %{
      "request.path" => "/admin/invite/#{@invite}",
      "request.query" => "token=#{@invite}&page=2",
      "live_view.uri" => "http://localhost/admin/invite?token=#{@invite}",
      "request.params" => %{
        "admin" => %{"email" => "someone@example.com", "password" => @password, "code" => @code},
        "list" => [%{"current_password" => @password}]
      },
      "live_view.event_params" => %{"password" => %{"nested" => @password}},
      "request.headers" => %{"cookie" => "[REDACTED]", "user-agent" => "test"}
    }

    scrubbed = ErrorFilter.sanitize(context)
    encoded = Jason.encode!(scrubbed)

    refute encoded =~ @password
    refute encoded =~ @code
    refute encoded =~ @invite
    assert scrubbed["request.params"]["admin"]["email"] == "someone@example.com"
    assert scrubbed["request.query"] == "token=[FILTERED]&page=2"
    assert scrubbed["request.path"] == "/admin/invite/[FILTERED]"
    assert scrubbed["request.headers"]["user-agent"] == "test"
  end

  test "Phoenix filters the same keys from its logs" do
    assert Phoenix.Logger.filter_values(%{
             "admin" => %{"password" => @password, "code" => @code, "email" => "e"},
             "token" => @invite
           }) == %{
             "admin" => %{"password" => "[FILTERED]", "code" => "[FILTERED]", "email" => "e"},
             "token" => "[FILTERED]"
           }

    for key <- ErrorFilter.secret_keys() do
      assert Phoenix.Logger.filter_values(%{"new_#{key}" => "v"}) == %{
               "new_#{key}" => "[FILTERED]"
             }
    end
  end

  test "an invitation link in the path isn't logged" do
    assert KickTrackerWeb.Endpoint.log_level(build_conn(:get, "/admin/invite/#{@invite}")) ==
             false

    assert KickTrackerWeb.Endpoint.log_level(build_conn(:get, "/admin/invite?token=x")) == :info
    assert KickTrackerWeb.Endpoint.log_level(build_conn(:get, "/c/somestreamer")) == :info
  end

  describe "with ErrorTracker on" do
    setup do
      Application.put_env(:error_tracker, :enabled, true)
      on_exit(fn -> Application.put_env(:error_tracker, :enabled, false) end)
    end

    test "a crash during a login stores no secret" do
      conn =
        build_conn(:post, "/admin/invite/#{@invite}?token=#{@invite}", %{
          "admin" => %{"email" => "someone@example.com", "password" => @password, "code" => @code}
        })

      ErrorTracker.Integrations.Plug.report_error(
        conn,
        {:error, %RuntimeError{message: "boom"}},
        []
      )

      ErrorTracker.report({:error, %RuntimeError{message: "boom in a live view"}}, [], %{
        "live_view.event_params" => %{
          "admin" => %{"password" => @password, "password_confirmation" => @password},
          "code" => @code
        }
      })

      stored = Repo.query!("SELECT context::text FROM error_tracker_occurrences").rows
      assert length(stored) == 2

      for [context] <- stored do
        refute context =~ @password
        refute context =~ @code
        refute context =~ @invite
      end
    end
  end
end
