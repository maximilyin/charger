defmodule Charger.Prices do
  @moduledoc """
  Catalog queries. Every function here reads the ETS cache and nothing else.
  """

  alias Charger.Prices.Cache
  alias Charger.Prices.Schedule

  @page_size 25
  @fuels [:gasoline_95, :gasoline_98, :diesel_a, :diesel_premium]

  def fuels, do: @fuels

  def query(params) when is_map(params) do
    snapshot = Cache.snapshot()
    fuel = normalize_fuel(params["fuel"] || params[:fuel])
    province = text(params["province"] || params[:province])
    municipality = text(params["municipality"] || params[:municipality])
    brand = text(params["brand"] || params[:brand])
    q = text(params["q"] || params[:q]) |> String.downcase()
    origin = origin(params)
    sort = if origin, do: :distance, else: normalize_sort(params["sort"] || params[:sort])

    scoped =
      snapshot.stations
      |> filter_eq(:province, province)
      |> filter_eq(:municipality, municipality)
      |> filter_query(q)

    priced =
      scoped
      |> Enum.flat_map(fn station ->
        case Map.get(station.prices, fuel) do
          nil -> []
          price -> [Map.put(station, :price, price)]
        end
      end)
      |> maybe_brand(brand)
      |> sort_stations(sort, origin)

    brands =
      scoped
      |> Enum.map(& &1.brand)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    provinces =
      snapshot.stations
      |> Enum.map(& &1.province)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    municipalities =
      snapshot.stations
      |> Enum.filter(fn station -> province == "" or station.province == province end)
      |> Enum.map(& &1.municipality)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    total = length(priced)
    per_page = take(params)
    pages = max(ceil_div(total, per_page), 1)
    page = params |> page_number() |> min(pages) |> max(1)
    prices = Enum.map(priced, & &1.price)
    now = Schedule.to_madrid(clock(params))

    %{
      status: snapshot.status,
      fecha: snapshot.fecha,
      fetched_at: snapshot.fetched_at,
      fuel: fuel,
      province: province,
      municipality: municipality,
      brand: brand,
      q: params["q"] || params[:q] || "",
      sort: sort,
      provinces: provinces,
      municipalities: municipalities,
      brands: brands,
      cached_total: length(snapshot.stations),
      cheapest: extremum(prices, &Enum.min/1),
      median: median(prices),
      dearest: extremum(prices, &Enum.max/1),
      total: total,
      page: page,
      pages: pages,
      stations:
        priced
        |> Enum.slice((page - 1) * per_page, per_page)
        |> Enum.map(fn station ->
          station
          |> Map.put(:open, Schedule.status(station.schedule, now))
          |> Map.put(:distance_m, distance_m(station, origin))
        end)
    }
  end

  def to_json(result) do
    %{
      status: result.status,
      source_timestamp: result.fecha,
      fetched_at: result.fetched_at && DateTime.to_iso8601(result.fetched_at),
      fuel: result.fuel,
      total: result.total,
      page: result.page,
      pages: result.pages,
      stations:
        Enum.map(result.stations, fn station ->
          %{
            id: station.id,
            brand: station.brand,
            address: station.address,
            municipality: station.municipality,
            province: station.province,
            locality: station.locality,
            schedule: station.schedule,
            latitude: station.latitude,
            longitude: station.longitude,
            maps_url: maps_url(station),
            price_per_liter: format_dot(station.price)
          }
        end)
    }
  end

  def maps_url(%{latitude: latitude, longitude: longitude})
      when is_binary(latitude) and is_binary(longitude) do
    "https://www.google.com/maps/search/?api=1&query=#{latitude},#{longitude}"
  end

  def maps_url(%{latitude: latitude, longitude: longitude})
      when is_number(latitude) and is_number(longitude) do
    "https://www.google.com/maps/search/?api=1&query=#{coord(latitude)},#{coord(longitude)}"
  end

  def maps_url(station) do
    query =
      [station.address, station.municipality, station.province, "Spain"]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")
      |> URI.encode_www_form()

    "https://www.google.com/maps/search/?api=1&query=#{query}"
  end

  def format_price(millis, "en") when is_integer(millis) do
    "€#{format_dot(millis)}"
  end

  def format_price(millis, _locale) when is_integer(millis) do
    {whole, frac} = split(millis)
    "#{whole},#{frac} €"
  end

  def format_delta(0, locale), do: format_price(0, locale)

  def format_delta(millis, "en") when is_integer(millis) and millis < 0 do
    "−€#{format_dot(abs(millis))}"
  end

  def format_delta(millis, "en") when is_integer(millis) do
    "+€#{format_dot(millis)}"
  end

  def format_delta(millis, locale) when is_integer(millis) and millis < 0 do
    "−#{format_price(abs(millis), locale)}"
  end

  def format_delta(millis, locale) when is_integer(millis) do
    "+#{format_price(millis, locale)}"
  end

  def source_clock(fecha) when is_binary(fecha) do
    case Regex.run(~r/\b(\d{1,2}):(\d{2})(?::\d{2})?\s*\z/, String.trim(fecha)) do
      [_, hour, minute] -> String.pad_leading(hour, 2, "0") <> ":" <> minute
      _ -> nil
    end
  end

  def source_clock(_fecha), do: nil

  def format_kilometers(meters, locale) when is_number(meters) and meters >= 0 do
    kilometers = meters / 1000

    text =
      if kilometers < 9.95 do
        :erlang.float_to_binary(Float.round(kilometers, 1), decimals: 1)
      else
        kilometers |> round() |> Integer.to_string()
      end

    if locale == "en", do: text, else: String.replace(text, ".", ",")
  end

  defp format_dot(millis) do
    {whole, frac} = split(millis)
    "#{whole}.#{frac}"
  end

  defp coord(number) do
    number
    |> :erlang.float_to_binary(decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp split(millis) do
    whole = div(millis, 1000)
    frac = millis |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    {whole, frac}
  end

  defp clock(params) do
    case params["now"] || params[:now] do
      %DateTime{} = now -> now
      _ -> DateTime.utc_now()
    end
  end

  defp filter_eq(stations, _field, ""), do: stations

  defp filter_eq(stations, field, value) do
    Enum.filter(stations, &(Map.get(&1, field) == value))
  end

  defp filter_query(stations, ""), do: stations

  defp filter_query(stations, q) do
    Enum.filter(stations, fn station ->
      [station.brand, station.address, station.municipality, station.locality]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(q)
    end)
  end

  defp maybe_brand(stations, ""), do: stations

  defp maybe_brand(stations, brand) do
    Enum.filter(stations, &(&1.brand == brand))
  end

  defp sort_stations(stations, :distance, origin) when not is_nil(origin) do
    Enum.sort_by(stations, fn station ->
      {distance_m(station, origin) || 1.0e12, station.price, station.brand, station.address}
    end)
  end

  defp sort_stations(stations, :price_desc, _origin) do
    Enum.sort_by(stations, &{-&1.price, &1.brand, &1.address})
  end

  defp sort_stations(stations, _sort, _origin) do
    Enum.sort_by(stations, &{&1.price, &1.brand, &1.address})
  end

  defp origin(params) do
    with {lat, _rest} <- number(params["near_lat"] || params[:near_lat]),
         {lng, _rest} <- number(params["near_lng"] || params[:near_lng]),
         true <- lat >= -90 and lat <= 90 and lng >= -180 and lng <= 180 do
      %{lat: lat, lng: lng}
    else
      _ -> nil
    end
  end

  defp number(value) when is_float(value), do: {value, ""}
  defp number(value) when is_integer(value), do: {value / 1, ""}
  defp number(value) when is_binary(value), do: Float.parse(String.trim(value))
  defp number(_value), do: :error

  defp distance_m(_station, nil), do: nil
  defp distance_m(station, %{lat: lat, lng: lng}), do: Charger.Geo.distance_m(station, lat, lng)

  defp normalize_fuel(fuel) when fuel in @fuels, do: fuel

  defp normalize_fuel(fuel) when is_binary(fuel) do
    case Enum.find(@fuels, &(Atom.to_string(&1) == fuel)) do
      nil -> :gasoline_95
      found -> found
    end
  end

  defp normalize_fuel(_), do: :gasoline_95

  defp normalize_sort("price_desc"), do: :price_desc
  defp normalize_sort(_), do: :price_asc

  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.trim()

  defp page_number(params) do
    case Integer.parse(to_string(params["page"] || params[:page] || "1")) do
      {page, ""} -> page
      _ -> 1
    end
  end

  defp take(params) do
    case Integer.parse(to_string(params["take"] || params[:take] || "")) do
      {count, ""} when count in 1..20_000 -> count
      _ -> per_page(params)
    end
  end

  defp per_page(params) do
    case Integer.parse(to_string(params["per_page"] || params[:per_page] || "")) do
      {count, ""} when count in 1..500 -> count
      _ -> @page_size
    end
  end

  defp extremum([], _fun), do: nil
  defp extremum(prices, fun), do: fun.(prices)

  defp median([]), do: nil

  defp median(prices) do
    sorted = Enum.sort(prices)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle) + 1, 2)
    end
  end

  defp ceil_div(_total, 0), do: 0
  defp ceil_div(0, _size), do: 0
  defp ceil_div(total, size), do: div(total + size - 1, size)
end
