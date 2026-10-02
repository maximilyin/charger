defmodule Charger.ChargersTest do
  use ExUnit.Case, async: false

  alias Charger.Chargers.Overlap
  alias Charger.Chargers.Parser

  test "groups connectors and unwraps excel coordinates" do
    %{sites: sites} = Parser.parse(Charger.Chargers.FixtureSource.csv())

    assert length(sites) == 2
    repsol = Enum.find(sites, &(&1.id == "SITE-A"))
    assert repsol.latitude == 40.432861
    assert repsol.longitude == -3.724194
    assert repsol.postal_code == "28001"
    assert repsol.schedule_type == "24/7"
    assert length(repsol.connectors) == 2
    assert Enum.map(repsol.connectors, & &1.power_kw) == [7.4, 50.0]

    puerto = Enum.find(sites, &(&1.id == "SITE-B"))
    assert puerto.address == "C/ Francia.\nPolígono"
    assert puerto.province == "Cádiz"
  end

  test "decodes a utf-16 export" do
    utf16 =
      :unicode.characters_to_binary(
        Charger.Chargers.FixtureSource.csv(),
        :utf8,
        {:utf16, :little}
      )

    assert %{sites: [%{id: "SITE-A"}, %{id: "SITE-B"}]} = Parser.parse(utf16)
  end

  test "joins by distance more often than by the written address" do
    fuel = [
      %{
        province: "MADRID",
        municipality: "Madrid",
        address: "CALLE ALCALÁ, 1",
        latitude: 40.0,
        longitude: -3.0
      },
      %{
        province: "MADRID",
        municipality: "Madrid",
        address: "OTRA, 9",
        latitude: 40.0002,
        longitude: -3.0
      },
      %{
        province: "MADRID",
        municipality: "Madrid",
        address: "LEJOS, 1",
        latitude: 41.0,
        longitude: -3.0
      }
    ]

    chargers = [
      %{
        province: "Madrid",
        municipality: "Madrid",
        address: "Calle Alcala, 1",
        latitude: 40.0,
        longitude: -3.0
      },
      %{
        province: "Madrid",
        municipality: "Madrid",
        address: "Calle Distinta",
        latitude: 40.0002,
        longitude: -3.0
      }
    ]

    report = Overlap.report(fuel, chargers)

    assert report.within_30m == 2
    assert report.within_80m == 2
    assert report.same_address == 1
  end

  test "cache keeps the parsed catalog" do
    snapshot = Charger.Chargers.snapshot()

    assert snapshot.status == :ready
    assert length(snapshot.sites) == 2
    assert snapshot.overlap.within_30m == 29
    assert snapshot.overlap.same_address == 1
  end

  test "lists chargers with power instead of a fuel price" do
    result = Charger.Chargers.query(%{"province" => "Madrid", "take" => 10})

    assert result.fuel == :charging
    assert Enum.map(result.stations, & &1.id) == ["SITE-A"]
    repsol = hd(result.stations)
    assert repsol.brand == "REPSOL"
    assert repsol.price == 50_000
    assert repsol.schedule == "24H"
    assert Enum.map(repsol.plugs, & &1.kind) == [:dc, :ac]
    assert Charger.Chargers.format_power(7400, "uk") == "7,4 kW"
    assert Charger.Chargers.format_power(50_000, "en") == "50 kW"
  end

  test "map points include every charger while the table stays paged" do
    result = Charger.Chargers.query(%{"take" => 1, "points" => true})

    assert length(result.stations) == 1
    assert length(result.points) == 2
    assert result.points |> Enum.map(& &1.id) |> Enum.sort() == ["SITE-A", "SITE-B"]
  end
end
