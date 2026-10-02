defmodule Charger.Chargers.Parser do
  @moduledoc """
  RIPREE public export: UTF-16 LE CSV, one row per connector.

  Rows are grouped into one site per `COD.INSTALACION`.
  """

  @columns %{
    community: "COMUNIDAD AUTONOMA",
    province: "PROVINCIA",
    municipality: "MUNICIPIO",
    latitude: "LATITUD",
    longitude: "LONGITUD",
    name: "NOMBRE INSTALACION",
    address: "DIRECCIÓN",
    postal_code: "CODIGO POSTAL",
    schedule_type: "TIPO HORARIO APERTURA",
    schedule: "HORARIO APERTURA",
    operator: "NOMBRE OPERADOR",
    id: "COD.INSTALACION",
    point_id: "ID. PUNTO DE RECARGA",
    connector_id: "ID. CONECTOR",
    connector_type: "TIPO CONECTOR",
    current: "TIPO DE CARGA",
    power: "POTENCIA MAXIMA"
  }

  def parse(payload) when is_binary(payload) do
    rows =
      payload
      |> decode()
      |> parse_csv()

    case rows do
      [] ->
        %{sites: []}

      [header | data] ->
        index = header_index(header)

        sites =
          data
          |> Enum.reduce(%{}, fn row, acc -> group(row, index, acc) end)
          |> Map.values()
          |> Enum.sort_by(& &1.id)

        %{sites: sites}
    end
  end

  defp group(row, index, acc) do
    id = field(row, index, :id)

    if id == "" do
      acc
    else
      connector = %{
        point_id: field(row, index, :point_id),
        id: field(row, index, :connector_id),
        type: field(row, index, :connector_type),
        current: field(row, index, :current),
        power_kw: power(field(row, index, :power))
      }

      Map.update(acc, id, site(row, index, id, connector), fn site ->
        %{site | connectors: site.connectors ++ [connector]}
      end)
    end
  end

  defp site(row, index, id, connector) do
    %{
      id: id,
      name: field(row, index, :name),
      operator: field(row, index, :operator),
      address: field(row, index, :address),
      postal_code: field(row, index, :postal_code),
      municipality: field(row, index, :municipality),
      province: field(row, index, :province),
      community: field(row, index, :community),
      latitude: coord(field(row, index, :latitude)),
      longitude: coord(field(row, index, :longitude)),
      schedule_type: field(row, index, :schedule_type),
      schedule: field(row, index, :schedule),
      connectors: [connector]
    }
  end

  defp field(row, index, key) do
    case Map.fetch(index, @columns[key]) do
      {:ok, at} -> row |> Enum.at(at, "") |> unwrap()
      :error -> ""
    end
  end

  defp header_index(header) do
    header
    |> Enum.with_index()
    |> Map.new(fn {name, at} -> {String.trim(name), at} end)
  end

  defp unwrap(value) do
    value = String.trim(value)

    case Regex.run(~r/\A="(.*)"\z/s, value) do
      [_, inner] -> inner
      _ -> value
    end
  end

  defp coord(value) do
    case Float.parse(String.replace(value, ",", ".")) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp power(value) do
    case Float.parse(String.replace(value, ",", ".")) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp decode(<<0xFF, 0xFE, rest::binary>>), do: utf16(rest, :little)
  defp decode(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest, :big)

  defp decode(<<_::8, 0, _::8, 0, _::binary>> = binary), do: utf16(binary, :little)
  defp decode(binary), do: binary

  defp utf16(binary, endian) do
    case :unicode.characters_to_binary(binary, {:utf16, endian}) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  def parse_csv(text) when is_binary(text) do
    text
    |> scan([], [], false, [])
    |> Enum.reverse()
    |> Enum.reject(&(&1 == [""]))
  end

  defp scan(<<>>, field, row, false, rows), do: finish_row(field, row, rows)

  defp scan(<<"\"", rest::binary>>, [], row, false, rows) do
    scan(rest, [], row, true, rows)
  end

  defp scan(<<"\"\"", rest::binary>>, field, row, true, rows) do
    scan(rest, [?" | field], row, true, rows)
  end

  defp scan(<<"\"", rest::binary>>, field, row, true, rows) do
    scan(rest, field, row, false, rows)
  end

  defp scan(<<";", rest::binary>>, field, row, false, rows) do
    scan(rest, [], [to_text(field) | row], false, rows)
  end

  defp scan(<<"\r\n", rest::binary>>, field, row, false, rows) do
    scan(rest, [], [], false, finish_row(field, row, rows))
  end

  defp scan(<<"\n", rest::binary>>, field, row, false, rows) do
    scan(rest, [], [], false, finish_row(field, row, rows))
  end

  defp scan(<<byte, rest::binary>>, field, row, quoted?, rows) do
    scan(rest, [byte | field], row, quoted?, rows)
  end

  defp finish_row([], [], rows), do: rows

  defp finish_row(field, row, rows) do
    [Enum.reverse([to_text(field) | row]) | rows]
  end

  defp to_text(bytes), do: bytes |> Enum.reverse() |> :erlang.list_to_binary()
end
