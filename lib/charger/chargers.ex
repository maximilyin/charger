defmodule Charger.Chargers do
  @moduledoc """
  Public charging installations, read from the ETS snapshot.
  """

  alias Charger.Chargers.Cache
  alias Charger.Geo

  def snapshot, do: Cache.snapshot()

  def sites, do: snapshot().sites

  @doc """
  Same catalog shape as fuel prices. There is no public price, so `price` is
  the fastest connector at the site, in watts.
  """
  def query(params) when is_map(params) do
    snapshot = snapshot()
    province = text(params["province"] || params[:province])
    municipality = text(params["municipality"] || params[:municipality])
    q = text(params["q"] || params[:q]) |> String.downcase()
    origin = origin(params)

    matched =
      snapshot.sites
      |> filter_eq(:province, province)
      |> filter_eq(:municipality, municipality)
      |> filter_query(q)
      |> Enum.map(&to_station/1)
      |> sort_stations(origin)

    provinces =
      snapshot.sites
      |> Enum.map(& &1.province)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    municipalities =
      snapshot.sites
      |> Enum.filter(fn site -> province == "" or site.province == province end)
      |> Enum.map(& &1.municipality)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    powers = Enum.map(matched, & &1.price) |> Enum.reject(&is_nil/1)
    total = length(matched)
    size = take(params)
    pages = max(ceil_div(total, size), 1)
    page = params |> page_number() |> min(pages) |> max(1)

    %{
      status: snapshot.status,
      fecha: nil,
      fetched_at: snapshot.fetched_at,
      fuel: :charging,
      province: province,
      municipality: municipality,
      brand: "",
      q: params["q"] || params[:q] || "",
      sort: if(origin, do: :distance, else: :power_desc),
      provinces: provinces,
      municipalities: municipalities,
      brands: [],
      cached_total: length(snapshot.sites),
      cheapest: extremum(powers, &Enum.min/1),
      median: median(powers),
      dearest: extremum(powers, &Enum.max/1),
      total: total,
      page: page,
      pages: pages,
      stations:
        matched
        |> Enum.slice((page - 1) * size, size)
        |> Enum.map(&Map.put(&1, :distance_m, distance_m(&1, origin)))
    }
  end

  def format_power(nil, _locale), do: "—"

  def format_power(watts, locale) when is_integer(watts) and watts >= 0 do
    text =
      if rem(watts, 1000) == 0 do
        Integer.to_string(div(watts, 1000))
      else
        :erlang.float_to_binary(watts / 1000, decimals: 1)
      end

    text = if locale == "en", do: text, else: String.replace(text, ".", ",")
    "#{text} kW"
  end

  def display_schedule(site) do
    type = Map.get(site, :schedule_type, "") || ""
    hours = Map.get(site, :schedule, "") || ""

    cond do
      clock_around?(type) or clock_around?(hours) -> "24H"
      hours == "" -> short_text(type)
      true -> short_hours(hours)
    end
  end

  defp to_station(site) do
    schedule = display_schedule(site)

    %{
      id: site.id,
      brand: sign(site),
      brand_title: title(site),
      address: site.address,
      municipality: site.municipality,
      province: site.province,
      locality: "",
      schedule: schedule,
      latitude: site.latitude,
      longitude: site.longitude,
      price: max_watts(site.connectors),
      plugs: plugs(site.connectors),
      prices: %{},
      open: if(schedule == "24H", do: :open_24h, else: :unknown),
      distance_m: nil
    }
  end

  defp sign(site) do
    cond do
      site.operator != "" -> site.operator |> String.split(~r/[\s,]+/, parts: 2) |> hd()
      site.name != "" -> site.name
      true -> ""
    end
  end

  defp title(site) do
    cond do
      site.operator != "" -> site.operator
      true -> site.name
    end
  end

  defp max_watts(connectors) do
    connectors
    |> Enum.map(&watts/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp plugs(connectors) do
    connectors
    |> Enum.reduce(%{}, fn connector, acc ->
      kind = current_kind(connector)
      power = watts(connector)
      Map.update(acc, {kind, power}, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{kind, power}, count} -> %{kind: kind, watts: power, count: count} end)
    |> Enum.reject(&(&1.kind == :other and is_nil(&1.watts)))
    |> Enum.sort_by(fn plug -> {plug.kind != :dc, is_nil(plug.watts), -(plug.watts || 0)} end)
  end

  defp current_kind(%{current: "DC" <> _rest}), do: :dc
  defp current_kind(%{current: "AC" <> _rest}), do: :ac
  defp current_kind(_connector), do: :other

  defp watts(%{power_kw: kw}) when is_float(kw), do: round(kw * 1000)
  defp watts(_connector), do: nil

  defp clock_around?(text) do
    up = text |> String.upcase() |> String.replace(~r/\s+/, "")
    String.contains?(up, "24/7") or String.contains?(up, "24H") or all_day?(text)
  end

  defp all_day?(text) do
    ranges = clock_ranges(text)
    ranges != [] and Enum.all?(ranges, &(&1 in ["00:00-23:59", "00:00-24:00"]))
  end

  defp short_hours(text) do
    case Enum.uniq(clock_ranges(text)) do
      [] -> short_text(text)
      [range] -> range
      ranges -> ranges |> Enum.take(2) |> Enum.join(" · ")
    end
  end

  defp clock_ranges(text) do
    Regex.scan(~r/(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})/, text)
    |> Enum.map(fn [_, h1, m1, h2, m2] ->
      "#{pad(h1)}:#{m1}-#{pad(h2)}:#{m2}"
    end)
  end

  defp pad(hour), do: String.pad_leading(hour, 2, "0")

  defp short_text(""), do: ""

  defp short_text(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) <= 28 do
      text
    else
      String.slice(text, 0, 28)
    end
  end

  defp filter_eq(sites, _field, ""), do: sites

  defp filter_eq(sites, field, value) do
    Enum.filter(sites, &(Map.get(&1, field) == value))
  end

  defp filter_query(sites, ""), do: sites

  defp filter_query(sites, q) do
    Enum.filter(sites, fn site ->
      [site.operator, site.name, site.address, site.municipality]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(q)
    end)
  end

  defp sort_stations(stations, origin) when not is_nil(origin) do
    Enum.sort_by(stations, fn station ->
      {distance_m(station, origin) || 1.0e12, -(station.price || 0), station.brand, station.id}
    end)
  end

  defp sort_stations(stations, _origin) do
    Enum.sort_by(stations, fn station ->
      {is_nil(station.price), -(station.price || 0), station.brand, station.id}
    end)
  end

  defp distance_m(_station, nil), do: nil
  defp distance_m(station, %{lat: lat, lng: lng}), do: Geo.distance_m(station, lat, lng)

  defp origin(params) do
    with {lat, _lat} <- number(params["near_lat"] || params[:near_lat]),
         {lng, _lng} <- number(params["near_lng"] || params[:near_lng]),
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

  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.trim()

  defp extremum([], _fun), do: nil
  defp extremum(values, fun), do: fun.(values)

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle) + 1, 2)
    end
  end

  defp take(params) do
    case Integer.parse(to_string(params["take"] || params[:take] || "")) do
      {count, ""} when count in 1..20_000 -> count
      _ -> 200
    end
  end

  defp page_number(params) do
    case Integer.parse(to_string(params["page"] || params[:page] || "1")) do
      {page, ""} -> page
      _ -> 1
    end
  end

  defp ceil_div(_total, 0), do: 0
  defp ceil_div(0, _size), do: 0
  defp ceil_div(total, size), do: div(total + size - 1, size)
end
