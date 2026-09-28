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

  # /data/v1: our own pages' chart data, nobody else's (§13.5). Counted
  # before the token is checked, so requests without one are limited too.
  pipeline :api do
    plug :accepts, ["json"]
    plug KickTrackerWeb.Plugs.RateLimit
    plug KickTrackerWeb.Plugs.DataToken
  end

  # The public read API (§13.10): a key issued by an admin, counted per
  # key by the rate limit, then required.
  pipeline :public_api do
    plug :accepts, ["json"]
    plug KickTrackerWeb.Plugs.ApiKey, :fetch
    plug KickTrackerWeb.Plugs.RateLimit
    plug KickTrackerWeb.Plugs.ApiKey, :require
  end

  # JSON for admin pages' charts: the admin's session, no page around it
  # (the controller answers 401 without an admin).
  pipeline :admin_api do
    plug :accepts, ["json"]
    plug :fetch_session
    # Checks only requests that change something: the GETs here pass, and
    # anything added later that writes is covered.
    plug :protect_from_forgery
    plug KickTrackerWeb.Plugs.RateLimit
    plug :fetch_current_admin
  end

  ## Public site (project.md §13.2)

  scope "/", KickTrackerWeb do
    pipe_through :browser

    get "/about/methodology", AboutController, :methodology
    get "/about/privacy", AboutController, :privacy
    get "/about/removal", AboutController, :removal
    get "/search", AboutController, :search

    live_session :public, on_mount: [KickTrackerWeb.DataToken] do
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

  # Channels' pictures, our copies (§12.9).
  pipeline :images do
    plug KickTrackerWeb.Plugs.RateLimit
  end

  scope "/img", KickTrackerWeb do
    pipe_through :images
    get "/channels/:id/avatar", AvatarController, :show
  end

  # History as JSON for our own pages' charts (§13.5); outside use goes
  # to /api/v1 with a key.
  scope "/data/v1", KickTrackerWeb.Data do
    pipe_through :api

    get "/channels/:slug/:series", ChannelController, :show
    get "/streams/:id", StreamController, :show
    get "/streams/:id/chatters", StreamController, :chatters
    get "/compare", CompareController, :show
    get "/sparklines/:slug", SparklineController, :show
  end

  scope "/api/v1", KickTrackerWeb.Api.V1 do
    pipe_through :public_api

    get "/channels", ChannelController, :index
    get "/live", ChannelController, :live
    get "/channels/:slug", ChannelController, :show
    get "/channels/:slug/now", ChannelController, :now
    get "/channels/:slug/streams", ChannelController, :streams
    get "/channels/:slug/chat-log/messages", ChatLogController, :messages
    get "/channels/:slug/chat-log/events", ChatLogController, :events
    get "/channels/:slug/:series", ChannelController, :series
    get "/streams/:id", StreamController, :show
    get "/streams/:id/chatters", StreamController, :chatters
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
      # The token goes in the query, which request logs leave out; the
      # path form is kept for links handed out before (see Endpoint.log_level/1).
      live "/invite", InviteLive
      live "/invite/:token", InviteLive
    end
  end

  scope "/admin", KickTrackerWeb.Admin do
    pipe_through [:browser, :require_admin]

    live_session :admin, on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}] do
      live "/", HealthLive
      live "/channels", ChannelsLive
      live "/groups", GroupsLive
      live "/api-keys", ApiKeysLive
      live "/subscriptions", SubscriptionsLive
      live "/dead-letters", DeadLettersLive
      live "/data", DataLive
      live "/anomalies", AnomaliesLive, :index
      live "/anomalies/:id", AnomaliesLive, :show
      live "/transfer", TransferLive
      live "/privacy", PrivacyLive
      live "/chat-log", ChatLogLive
      live "/settings", SettingsLive
      live "/admins", AdminsLive
      live "/audit", AuditLive
      live "/account", AccountLive
    end
  end

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    get "/transfers/:id/download", KickTrackerWeb.Admin.TransferController, :download
    get "/chat-log/export.csv", KickTrackerWeb.Admin.ChatLogController, :export

    live_dashboard "/dashboard",
      metrics: KickTrackerWeb.Telemetry,
      # Read-only: no killing processes from a browser tab (its default,
      # stated so a change is deliberate).
      allow_destructive_actions: false,
      on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}],
      csp_nonce_assign_key: :csp_nonce

    error_tracker_dashboard("/errors",
      on_mount: [{KickTrackerWeb.AdminAuth, :require_admin}],
      csp_nonce_assign_key: :csp_nonce
    )
  end

  scope "/admin", KickTrackerWeb.Admin do
    pipe_through :admin_api

    get "/anomalies/:id/chart", AnomaliesController, :chart
  end

  # The Swoosh mailbox preview in development.
  if Application.compile_env(:kick_tracker, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
