defmodule Charger.Chargers.Overlap do
  @moduledoc """
  How many fuel stations sit on the same site as a public charger.

  Address text rarely matches: the two catalogs abbreviate streets differently.
  Coordinates are the useful join. Thirty metres is the same forecourt; eighty
  metres also catches the charger across the access road.
  """

  @cell 0.001

  def report(fuel_stations, charger_sites)
      when is_list(fuel_stations) and is_list(charger_sites) do
    grid =
      Enum.reduce(charger_sites, %{}, fn site, acc ->
        case coords(site) do
          nil -> acc
          pair -> Map.update(acc, cell(pair), [site], &[site | &1])
        end
      end)

    addresses =
      Map.new(charger_sites, fn site ->
        {place_key(site.province, site.municipality, site.address), true}
      end)

    counts =
      Enum.reduce(fuel_stations, %{m30: 0, m50: 0, m80: 0, address: 0}, fn station, acc ->
        nearest = nearest_m(station, grid)

        acc
        |> count(:m30, nearest != nil and nearest <= 30)
        |> count(:m50, nearest != nil and nearest <= 50)
        |> count(:m80, nearest != nil and nearest <= 80)
        |> count(:address, address_hit?(station, addresses))
      end)

    %{
      fuel_stations: length(fuel_stations),
      charger_sites: length(charger_sites),
      within_30m: counts.m30,
      within_50m: counts.m50,
      within_80m: counts.m80,
      same_address: counts.address
    }
  end

  defp count(acc, _key, false), do: acc
  defp count(acc, key, true), do: Map.update!(acc, key, &(&1 + 1))

  defp address_hit?(station, addresses) do
    key = place_key(station.province, station.municipality, station.address)
    key != nil and Map.has_key?(addresses, key)
  end

  defp nearest_m(station, grid) do
    case coords(station) do
      nil ->
        nil

      pair ->
        {cx, cy} = cell(pair)

        for dx <- -1..1,
            dy <- -1..1,
            site <- Map.get(grid, {cx + dx, cy + dy}, []),
            reduce: nil do
          best ->
            distance = distance_m(pair, {site.latitude, site.longitude})

            if best == nil or distance < best, do: distance, else: best
        end
    end
  end

  defp coords(%{latitude: lat, longitude: lng}) do
    case {number(lat), number(lng)} do
      {{lat, _}, {lng, _}} -> {lat, lng}
      _ -> nil
    end
  end

  defp coords(_), do: nil

  defp number(value) when is_float(value), do: {value, ""}
  defp number(value) when is_integer(value), do: {value / 1, ""}
  defp number(value) when is_binary(value), do: Float.parse(value)
  defp number(_), do: :error

  defp cell({lat, lng}), do: {round(lat / @cell), round(lng / @cell)}

  defp place_key(province, municipality, address) do
    [province, municipality, address]
    |> Enum.map(&fold/1)
    |> case do
      [_, _, ""] -> nil
      parts -> parts
    end
  end

  defp fold(nil), do: ""

  defp fold(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{M}/u, "")
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/u, " ")
    |> String.trim()
  end

  defp distance_m({lat1, lon1}, {lat2, lon2}) do
    radius = 6_371_000
    phi1 = degrees(lat1)
    phi2 = degrees(lat2)
    dphi = degrees(lat2 - lat1)
    dlambda = degrees(lon2 - lon1)

    haversine =
      :math.sin(dphi / 2) * :math.sin(dphi / 2) +
        :math.cos(phi1) * :math.cos(phi2) * :math.sin(dlambda / 2) * :math.sin(dlambda / 2)

    2 * radius * :math.asin(min(1.0, :math.sqrt(haversine)))
  end

  defp degrees(value), do: value * :math.pi() / 180
end
