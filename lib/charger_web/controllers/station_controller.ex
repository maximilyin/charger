defmodule ChargerWeb.StationController do
  use ChargerWeb, :controller

  def index(conn, params) do
    json(conn, Charger.Prices.to_json(Charger.Prices.query(params)))
  end
end
