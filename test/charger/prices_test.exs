defmodule Charger.PricesTest do
  use ExUnit.Case, async: true

  test "filters by province and sorts cheapest gasoline first" do
    result = Charger.Prices.query(%{"province" => "MADRID", "fuel" => "gasoline_95"})

    assert result.status == :ready
    assert Enum.map(result.stations, & &1.brand) == ["REPSOL", "CEPSA"]
    assert hd(result.stations).price == 1759
    assert result.cheapest == 1759
    assert result.dearest == 1869
    assert result.median == 1814
    assert result.cached_total == 29
    assert hd(result.stations).open == :open_24h
  end

  test "hides stations that do not sell the selected fuel" do
    result = Charger.Prices.query(%{"province" => "MADRID", "fuel" => "diesel_a"})

    assert Enum.map(result.stations, & &1.brand) == ["CEPSA"]
    assert hd(result.stations).price == 1994
  end

  test "searches by address" do
    result = Charger.Prices.query(%{"q" => "moret"})

    assert Enum.map(result.stations, & &1.brand) == ["CEPSA"]
  end

  test "paginates the cached catalog" do
    result = Charger.Prices.query(%{"page" => "2"})

    assert result.total == 29
    assert result.pages == 2
    assert result.page == 2
    assert length(result.stations) == 4
  end

  test "builds a google maps link from coordinates" do
    url =
      Charger.Prices.maps_url(%{
        latitude: "40.432861",
        longitude: "-3.724194",
        address: "PASEO MORET, 7",
        municipality: "Madrid",
        province: "MADRID"
      })

    assert url == "https://www.google.com/maps/search/?api=1&query=40.432861,-3.724194"
  end

  test "formats prices for the three locales" do
    assert Charger.Prices.format_price(1869, "uk") == "1,869 €"
    assert Charger.Prices.format_price(1869, "es") == "1,869 €"
    assert Charger.Prices.format_price(1869, "en") == "€1.869"
    assert Charger.Prices.format_delta(-55, "uk") == "−0,055 €"
    assert Charger.Prices.format_delta(55, "en") == "+€0.055"
    assert Charger.Prices.source_clock("02/10/2026 8:36:47") == "08:36"
    assert Charger.Prices.format_kilometers(1400, "uk") == "1,4"
    assert Charger.Prices.format_kilometers(1400, "en") == "1.4"
    assert Charger.Prices.format_kilometers(12_400, "es") == "12"
  end

  test "sorts by distance when a point is given" do
    result =
      Charger.Prices.query(%{
        "province" => "MADRID",
        "fuel" => "gasoline_95",
        "near_lat" => "40.44",
        "near_lng" => "-3.72",
        "take" => 10
      })

    assert Enum.map(result.stations, & &1.brand) == ["REPSOL", "CEPSA"]
    assert is_float(hd(result.stations).distance_m)
    assert result.cheapest == 1759
  end

  test "map points include every match while the table stays paged" do
    paged = Charger.Prices.query(%{"take" => 2})
    assert paged.points == []
    assert length(paged.stations) == 2

    result = Charger.Prices.query(%{"take" => 2, "points" => true})
    assert length(result.stations) == 2
    assert length(result.points) == 29

    assert Enum.all?(result.points, fn point ->
             is_float(point.lat) and is_float(point.lng)
           end)

    refute Charger.Geo.marker(%{
             id: "outside",
             latitude: "0",
             longitude: "0",
             price: 1,
             brand: "X",
             address: "",
             municipality: ""
           })
  end
end
