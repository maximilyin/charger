defmodule Charger.Prices.Parser do
  @moduledoc """
  Turns the ministry JSON dump into stations with prices in thousandths of a euro.
  """

  @price_fields %{
    "Precio Gasolina 95 E5" => :gasoline_95,
    "Precio Gasolina 98 E5" => :gasoline_98,
    "Precio Gasoleo A" => :diesel_a,
    "Precio Gasoleo Premium" => :diesel_premium
  }

  def parse(payload) when is_map(payload) do
    stations =
      payload
      |> Map.get("ListaEESSPrecio", [])
      |> Enum.flat_map(&parse_station/1)

    %{
      stations: stations,
      fecha: payload["Fecha"],
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    }
  end

  defp parse_station(raw) when is_map(raw) do
    prices =
      Map.new(@price_fields, fn {field, key} -> {key, parse_price(raw[field])} end)
      |> Map.reject(fn {_key, price} -> is_nil(price) end)

    id = raw["IDEESS"] |> to_string() |> String.trim()

    if id == "" do
      []
    else
      [
        %{
          id: id,
          brand: text(raw["Rótulo"]),
          address: text(raw["Dirección"]),
          municipality: text(raw["Municipio"]),
          province: text(raw["Provincia"]),
          locality: text(raw["Localidad"]),
          schedule: text(raw["Horario"]),
          latitude: parse_coord(raw["Latitud"]),
          longitude: parse_coord(raw["Longitud (WGS84)"]),
          prices: prices
        }
      ]
    end
  end

  defp parse_station(_), do: []

  def parse_price(value) when is_binary(value) do
    cleaned = value |> String.trim() |> String.replace(~r/[[:space:]]/u, "")

    case Regex.run(~r/\A(\d+)[.,](\d{1,3})\z/, cleaned) do
      [_, whole, frac] ->
        String.to_integer(whole) * 1000 + String.to_integer(String.pad_trailing(frac, 3, "0"))

      _ ->
        nil
    end
  end

  def parse_price(_), do: nil

  def parse_coord(value) when is_binary(value) do
    cleaned = value |> String.trim() |> String.replace(~r/[[:space:]]/u, "")

    case Regex.run(~r/\A(-?)(\d+)[.,](\d+)\z/, cleaned) do
      [_, sign, whole, frac] -> "#{sign}#{whole}.#{frac}"
      _ -> nil
    end
  end

  def parse_coord(_), do: nil

  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.trim()
end
