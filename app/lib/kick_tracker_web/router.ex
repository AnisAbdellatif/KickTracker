defmodule KickTrackerWeb.Router do
  use KickTrackerWeb, :router

  import KickTrackerWeb.AdminAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KickTrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KickTrackerWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Admin (project.md §13.8)

  scope "/admin", KickTrackerWeb.Admin do
    pipe_through [:browser, :redirect_if_admin]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/admin", KickTrackerWeb.Admin do
    pipe_through :browser

    delete "/logout", SessionController, :delete

    live_session :admin_invite, on_mount: [{KickTrackerWeb.AdminAuth, :public}] do
      live "/invite/:token", InviteLive
    end
  end

  scope "/admin", KickTrackerWeb.Admin do
    pipe_through [:browser, :require_admin]

    live_session :admin, on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}] do
      live "/", HealthLive
      live "/channels", ChannelsLive
      live "/admins", AdminsLive
      live "/account", AccountLive
    end
  end

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    live_dashboard "/dashboard",
      metrics: KickTrackerWeb.Telemetry,
      on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}]
  end

  # The Swoosh mailbox preview in development.
  if Application.compile_env(:kick_tracker, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
