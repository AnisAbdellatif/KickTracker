defmodule KickTrackerWeb.Router do
  use KickTrackerWeb, :router

  import KickTrackerWeb.AdminAuth
  import Phoenix.LiveDashboard.Router
  import ErrorTracker.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KickTrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    # A strict baseline; ContentSecurityPolicy replaces it with the full
    # policy and this request's script nonce.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    }

    plug KickTrackerWeb.Plugs.ContentSecurityPolicy
    plug KickTrackerWeb.Plugs.RateLimit
    plug :fetch_current_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KickTrackerWeb.Plugs.RateLimit
  end

  ## Public site (project.md §13.2)

  scope "/", KickTrackerWeb do
    pipe_through :browser

    get "/about/methodology", AboutController, :methodology
    get "/about/privacy", AboutController, :privacy
    get "/about/removal", AboutController, :removal
    get "/search", AboutController, :search

    live_session :public do
      live "/", HomeLive
      live "/compare", CompareLive
      live "/category/:slug", CategoryLive
      live "/c/:slug", ChannelLive, :overview
      live "/c/:slug/streams", ChannelLive, :streams
      live "/c/:slug/chat", ChannelLive, :chat
      live "/c/:slug/support", ChannelLive, :support
      live "/c/:slug/categories", ChannelLive, :categories
      live "/c/:slug/streams/:id", StreamLive
    end
  end

  scope "/", KickTrackerWeb do
    get "/healthz", HealthzController, :show
  end

  # History as cacheable JSON (§13.5), versioned from the start.
  scope "/data/v1", KickTrackerWeb.Data do
    pipe_through :api

    get "/channels/:slug/:series", ChannelController, :show
    get "/streams/:id", StreamController, :show
    get "/streams/:id/chatters", StreamController, :chatters
    get "/compare", CompareController, :show
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
      live "/groups", GroupsLive
      live "/subscriptions", SubscriptionsLive
      live "/dead-letters", DeadLettersLive
      live "/data", DataLive
      live "/privacy", PrivacyLive
      live "/settings", SettingsLive
      live "/admins", AdminsLive
      live "/audit", AuditLive
      live "/account", AccountLive
    end
  end

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    live_dashboard "/dashboard",
      metrics: KickTrackerWeb.Telemetry,
      on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}],
      csp_nonce_assign_key: :csp_nonce

    error_tracker_dashboard("/errors",
      on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}],
      csp_nonce_assign_key: :csp_nonce
    )
  end

  # The Swoosh mailbox preview in development.
  if Application.compile_env(:kick_tracker, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
