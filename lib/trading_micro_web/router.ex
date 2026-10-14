defmodule TradingMicroWeb.Router do
  use TradingMicroWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TradingMicroWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Liveness + recorder health; trading_hub's /api/cluster-health pings it.
  scope "/", TradingMicroWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # app_status's shared /status and /status/metrics (its own Plug.Router).
  forward "/status", AppStatus.Plug

  scope "/", TradingMicroWeb do
    pipe_through :browser

    live "/", RecorderLive, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:trading_micro, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TradingMicroWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
