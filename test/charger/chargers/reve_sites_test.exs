defmodule Charger.Chargers.ReveSitesTest do
  use ExUnit.Case, async: true

  alias Charger.Chargers.ReveSites

  test "builds the site shape the charging catalog reads" do
    [site] =
      ReveSites.from_locations([
        %{
          "id" => "loc-1",
          "name" => "Estación Norte",
          "cpo_name" => "ZUNDER",
          "address" => "Avenida de Burgos 1",
          "city" => "Madrid",
          "city_code" => "079",
          "region" => "28",
          "state" => "13",
          "postal_code" => "28050",
          "coordinates" => %{"latitude" => "40.48", "longitude" => "-3.66"},
          "opening_times" => %{"twentyfourseven" => true},
          "evses" => [
            %{
              "evse_id" => "ES*ZUN*E1",
              "connectors" => [
                %{
                  "id" => "c1",
                  "standard" => "IEC_62196_T2_COMBO",
                  "power_type" => "DC",
                  "max_electric_power" => 150_000
                }
              ]
            }
          ]
        }
      ])

    assert site.id == "loc-1"
    assert site.operator == "ZUNDER"
    assert site.province == "Madrid"
    assert site.community == "Madrid, Comunidad de"
    assert site.latitude == 40.48
    assert site.longitude == -3.66
    assert Charger.Chargers.display_schedule(site) == "24H"

    assert site.connectors == [
             %{
               point_id: "ES*ZUN*E1",
               id: "c1",
               type: "IEC_62196_T2_COMBO",
               current: "DC",
               power_kw: 150.0,
               rates: []
             }
           ]
  end

  test "keeps the energy prices of a connector and drops a reservation fee" do
    [site] =
      ReveSites.from_locations([
        %{
          "id" => "loc-1",
          "evses" => [
            %{
              "connectors" => [
                %{
                  "id" => "c1",
                  "power_type" => "AC_3_PHASE",
                  "max_electric_power" => 6_900,
                  "tariffs" => [
                    %{
                      "elements" => [
                        %{
                          "price_components" => [
                            %{"type" => "ENERGY", "price" => 0.29, "vat" => 21}
                          ],
                          "restrictions" => %{
                            "max_power" => 22,
                            "start_time" => "07:00",
                            "end_time" => "22:59"
                          }
                        },
                        %{
                          "price_components" => [
                            %{"type" => "FLAT", "price" => 0.8, "vat" => 21}
                          ],
                          "restrictions" => %{"reservation" => "RESERVATION_EXPIRES"}
                        },
                        %{
                          "price_components" => [
                            %{"type" => "ENERGY", "price" => 8676.82, "vat" => 21}
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ])

    assert [%{power_kw: 6.9, rates: [rate]}] = site.connectors
    assert rate.net == 290
    assert rate.vat == 21
    assert rate.max_kw == 22.0
    assert rate.start == 7 * 60
    assert rate.stop == 22 * 60 + 59
  end

  test "one INE municipality code gets one readable name" do
    sites =
      ReveSites.from_locations([
        place("a", "MADRID", "28", "079"),
        place("b", "Madrid", "28", "079"),
        place("c", "Madird", "28", "079"),
        place("d", "VILLAMANRIQUE DE LA CONDESA", "41", "098"),
        place("e", "L'HOSPITALET DE LLOBREGAT", "08", "101")
      ])

    names = Map.new(sites, &{&1.id, &1.municipality})

    assert names["a"] == "Madrid"
    assert names["b"] == "Madrid"
    assert names["c"] == "Madrid"
    assert names["d"] == "Villamanrique de la Condesa"
    assert names["e"] == "L'Hospitalet de Llobregat"
  end

  test "the province falls back to the postal code and hours become ranges" do
    [site] =
      ReveSites.from_locations([
        "x"
        |> place("Cullera", nil, nil)
        |> Map.merge(%{
          "postal_code" => "46400",
          "opening_times" => %{
            "twentyfourseven" => false,
            "regular_hours" => [
              %{"weekday" => 2, "period_begin" => "09:00", "period_end" => "21:30"},
              %{"weekday" => 1, "period_begin" => "09:00", "period_end" => "21:30"}
            ]
          }
        })
      ])

    assert site.province == "Valencia/València"
    assert site.municipality == "Cullera"
    assert Charger.Chargers.display_schedule(site) == "09:00-21:30"
  end

  defp place(id, city, region, city_code) do
    %{"id" => id, "city" => city, "region" => region, "city_code" => city_code}
  end
end
