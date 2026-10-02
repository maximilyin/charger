defmodule ChargerWeb.StationControllerTest do
  use ChargerWeb.ConnCase, async: true

  test "serves stations from the cache without calling the source again", %{conn: conn} do
    before = Charger.Prices.FixtureSource.fetch_count()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/stations?province=MADRID&fuel=gasoline_95")

    body = json_response(conn, 200)

    assert body["status"] == "ready"
    assert body["total"] == 2
    assert Enum.map(body["stations"], & &1["brand"]) == ["REPSOL", "CEPSA"]
    assert hd(body["stations"])["price_per_liter"] == "1.759"
    assert hd(body["stations"])["latitude"] == "40.432861"
    assert hd(body["stations"])["maps_url"] =~ "40.432861,-3.724194"
    assert Charger.Prices.FixtureSource.fetch_count() == before
  end
end
