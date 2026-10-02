defmodule Charger.Prices.ParserTest do
  use ExUnit.Case, async: true

  alias Charger.Prices.Parser

  test "parses comma prices into thousandths of a euro" do
    assert Parser.parse_price("1,869") == 1869
    assert Parser.parse_price("1.759") == 1759
    assert Parser.parse_price(" 2,109 ") == 2109
    assert Parser.parse_price("1,8") == 1800
    assert Parser.parse_price("") == nil
    assert Parser.parse_price(nil) == nil
  end

  test "parses ministry coordinates with a comma decimal" do
    assert Parser.parse_coord("40,432861") == "40.432861"
    assert Parser.parse_coord("-3,724194") == "-3.724194"
    assert Parser.parse_coord("") == nil
  end

  test "keeps only fuels that have a price" do
    %{stations: [station], fecha: fecha} =
      Parser.parse(%{
        "Fecha" => "02/10/2026 8:36:47",
        "ListaEESSPrecio" => [
          %{
            "IDEESS" => "10943",
            "Rótulo" => "CEPSA",
            "Dirección" => "PASEO MORET, 7",
            "Municipio" => "Madrid",
            "Provincia" => "MADRID",
            "Localidad" => "Madrid",
            "Horario" => "L-V: 08:00-21:00",
            "Latitud" => "40,432861",
            "Longitud (WGS84)" => "-3,724194",
            "Precio Gasolina 95 E5" => "1,869",
            "Precio Gasolina 98 E5" => "",
            "Precio Gasoleo A" => "1,994",
            "Precio Gasoleo Premium" => ""
          },
          %{"IDEESS" => "  "}
        ]
      })

    assert fecha == "02/10/2026 8:36:47"
    assert station.id == "10943"
    assert station.brand == "CEPSA"
    assert station.prices == %{gasoline_95: 1869, diesel_a: 1994}
    assert station.latitude == "40.432861"
    assert station.longitude == "-3.724194"
  end
end
