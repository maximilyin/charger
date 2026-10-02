defmodule ChargerWeb.Router do
  use ChargerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChargerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ChargerWeb.Plugs.Locale
    plug ChargerWeb.Plugs.ClientSession
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChargerWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :switch

    live_session :catalog, on_mount: ChargerWeb.LiveLocale do
      live "/", CatalogLive
    end
  end

  scope "/api", ChargerWeb do
    pipe_through :api

    get "/stations", StationController, :index
  end

  if Application.compile_env(:charger, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ChargerWeb.Telemetry
    end
  end
end
