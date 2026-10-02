defmodule Charger.Prices.FixtureSource do
  @moduledoc false

  @key {__MODULE__, :fetches}

  def fetch do
    :persistent_term.put(@key, fetch_count() + 1)
    {:ok, payload()}
  end

  def fetch_count, do: :persistent_term.get(@key, 0)

  def payload do
    extras =
      Enum.map(1..26, fn i ->
        raw(
          "4#{String.pad_leading(Integer.to_string(i), 4, "0")}",
          "GALP",
          "CALLE #{i}",
          "Valencia",
          "VALENCIA",
          %{
            "Precio Gasolina 95 E5" =>
              "1,#{String.pad_leading(Integer.to_string(100 + i), 3, "0")}"
          }
        )
      end)

    %{
      "Fecha" => "02/10/2026 8:36:47",
      "Nota" => "fixture",
      "ResultadoConsulta" => "OK",
      "ListaEESSPrecio" => [
        raw("10943", "CEPSA", "PASEO MORET, 7", "Madrid", "MADRID", %{
          "Precio Gasolina 95 E5" => "1,869",
          "Precio Gasoleo A" => "1,994",
          "Horario" => "L-V: 08:00-21:00; S: 09:00-14:00"
        }),
        raw("20001", "REPSOL", "CALLE ALCALA, 1", "Madrid", "MADRID", %{
          "Precio Gasolina 95 E5" => "1,759"
        }),
        raw("30001", "BP", "AVENIDA DIAGONAL, 100", "Barcelona", "BARCELONA", %{
          "Precio Gasolina 95 E5" => "1,910"
        })
        | extras
      ]
    }
  end

  defp raw(id, brand, address, municipality, province, prices) do
    Map.merge(
      %{
        "IDEESS" => id,
        "Rótulo" => brand,
        "Dirección" => address,
        "Municipio" => municipality,
        "Provincia" => province,
        "Localidad" => municipality,
        "Horario" => "L-D: 24H",
        "Latitud" => "40,432861",
        "Longitud (WGS84)" => "-3,724194",
        "Precio Gasolina 95 E5" => "",
        "Precio Gasolina 98 E5" => "",
        "Precio Gasoleo A" => "",
        "Precio Gasoleo Premium" => ""
      },
      prices
    )
  end
end
