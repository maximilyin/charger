defmodule Charger.Chargers.ReveSites do
  @moduledoc """
  Reve locations in the same site shape the RIPREE parser builds.

  Reve gives the province and the community as INE codes. The city is typed by
  each operator, so one municipality can arrive as `MADRID`, `Madrid` and
  `Madird`. The name shown comes from the INE municipality code: the spelling
  most locations with that code use, preferring one not written in capitals.
  """

  @provinces %{
    "01" => "Araba/Álava",
    "02" => "Albacete",
    "03" => "Alicante/Alacant",
    "04" => "Almería",
    "05" => "Ávila",
    "06" => "Badajoz",
    "07" => "Balears, Illes",
    "08" => "Barcelona",
    "09" => "Burgos",
    "10" => "Cáceres",
    "11" => "Cádiz",
    "12" => "Castellón/Castelló",
    "13" => "Ciudad Real",
    "14" => "Córdoba",
    "15" => "Coruña, A",
    "16" => "Cuenca",
    "17" => "Girona",
    "18" => "Granada",
    "19" => "Guadalajara",
    "20" => "Gipuzkoa",
    "21" => "Huelva",
    "22" => "Huesca",
    "23" => "Jaén",
    "24" => "León",
    "25" => "Lleida",
    "26" => "Rioja, La",
    "27" => "Lugo",
    "28" => "Madrid",
    "29" => "Málaga",
    "30" => "Murcia",
    "31" => "Navarra",
    "32" => "Ourense",
    "33" => "Asturias",
    "34" => "Palencia",
    "35" => "Palmas, Las",
    "36" => "Pontevedra",
    "37" => "Salamanca",
    "38" => "Santa Cruz de Tenerife",
    "39" => "Cantabria",
    "40" => "Segovia",
    "41" => "Sevilla",
    "42" => "Soria",
    "43" => "Tarragona",
    "44" => "Teruel",
    "45" => "Toledo",
    "46" => "Valencia/València",
    "47" => "Valladolid",
    "48" => "Bizkaia",
    "49" => "Zamora",
    "50" => "Zaragoza",
    "51" => "Ceuta",
    "52" => "Melilla"
  }

  @communities %{
    "01" => "Andalucía",
    "02" => "Aragón",
    "03" => "Asturias, Principado de",
    "04" => "Balears, Illes",
    "05" => "Canarias",
    "06" => "Cantabria",
    "07" => "Castilla y León",
    "08" => "Castilla - La Mancha",
    "09" => "Cataluña",
    "10" => "Comunitat Valenciana",
    "11" => "Extremadura",
    "12" => "Galicia",
    "13" => "Madrid, Comunidad de",
    "14" => "Murcia, Región de",
    "15" => "Navarra, Comunidad Foral de",
    "16" => "País Vasco",
    "17" => "Rioja, La",
    "18" => "Ceuta",
    "19" => "Melilla"
  }

  @small_words ~w(a d de del e el en i l la las los y)

  def from_locations(locations) when is_list(locations) do
    names = municipality_names(locations)

    locations
    |> Enum.flat_map(fn location ->
      case site(location, names) do
        nil -> []
        site -> [site]
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp site(%{"id" => id} = location, names) when is_binary(id) and id != "" do
    {schedule_type, schedule} = schedule(location["opening_times"])
    {latitude, longitude} = coordinates(location["coordinates"])

    %{
      id: id,
      name: text(location["name"]),
      operator: text(location["cpo_name"]),
      address: text(location["address"]),
      postal_code: text(location["postal_code"]),
      municipality: municipality(location, names),
      province: Map.get(@provinces, province_code(location), ""),
      community: Map.get(@communities, text(location["state"]), ""),
      latitude: latitude,
      longitude: longitude,
      schedule_type: schedule_type,
      schedule: schedule,
      connectors: connectors(location["evses"])
    }
  end

  defp site(_location, _names), do: nil

  defp province_code(location) do
    case text(location["region"]) do
      "" ->
        location["postal_code"] |> text() |> String.slice(0, 2)

      code ->
        code
    end
  end

  defp municipality(location, names) do
    case Map.fetch(names, municipality_code(location)) do
      {:ok, name} -> name
      :error -> location["city"] |> text() |> readable()
    end
  end

  defp municipality_code(location) do
    with region when is_binary(region) and region != "" <- location["region"],
         city when is_binary(city) and city != "" <- location["city_code"] do
      region <> city
    else
      _ -> nil
    end
  end

  defp municipality_names(locations) do
    locations
    |> Enum.reduce(%{}, fn location, acc ->
      case {municipality_code(location), text(location["city"])} do
        {nil, _city} ->
          acc

        {_code, ""} ->
          acc

        {code, city} ->
          Map.update(acc, code, %{city => 1}, &Map.update(&1, city, 1, fn n -> n + 1 end))
      end
    end)
    |> Map.new(fn {code, spellings} ->
      {city, _count} =
        Enum.max_by(spellings, fn {city, count} -> {not capitals?(city), count, city} end)

      {code, readable(city)}
    end)
  end

  defp readable(city) do
    if capitals?(city), do: title_case(city), else: city
  end

  defp capitals?(text), do: text == String.upcase(text) and text != String.downcase(text)

  defp title_case(text) do
    text
    |> String.downcase()
    |> String.split(" ", trim: true)
    |> Enum.with_index()
    |> Enum.map_join(" ", fn
      {word, index} when index > 0 and word in @small_words -> word
      {word, _index} -> capitalize_parts(word)
    end)
  end

  defp capitalize_parts(word) do
    ~r/([\-\/'])/
    |> Regex.split(word, include_captures: true)
    |> Enum.map_join(&String.capitalize/1)
  end

  defp schedule(%{"twentyfourseven" => true}), do: {"24H", ""}

  defp schedule(%{"regular_hours" => hours}) when is_list(hours) do
    ranges =
      hours
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(&{&1["weekday"], &1["period_begin"]})
      |> Enum.map(&"#{&1["period_begin"]} - #{&1["period_end"]}")

    {"", Enum.join(ranges, " ")}
  end

  defp schedule(_opening_times), do: {"", ""}

  defp connectors(evses) when is_list(evses) do
    for %{} = evse <- evses,
        %{} = connector <- List.wrap(evse["connectors"]) do
      %{
        point_id: text(evse["evse_id"]),
        id: text(connector["id"]),
        type: text(connector["standard"]),
        current: text(connector["power_type"]),
        power_kw: kilowatts(connector["max_electric_power"]),
        rates: energy_rates(connector["tariffs"])
      }
    end
  end

  defp connectors(_evses), do: []

  defp kilowatts(watts) when is_number(watts) and watts > 0, do: watts / 1000

  defp kilowatts(watts) when is_binary(watts) do
    case Float.parse(watts) do
      {value, _rest} -> kilowatts(value)
      :error -> nil
    end
  end

  defp kilowatts(_watts), do: nil

  # Energy price bands of one connector. `net` is thousandths of a euro before
  # VAT. A price above 5 euro is a bad value in the feed and is left out.
  # Reservation fees are not the price of a charge, so those elements are left out.
  defp energy_rates(tariffs) when is_list(tariffs) do
    for tariff <- tariffs,
        is_map(tariff),
        element <- List.wrap(tariff["elements"]),
        is_map(element),
        restrictions = element["restrictions"] || %{},
        is_map(restrictions),
        not Map.has_key?(restrictions, "reservation"),
        component <- List.wrap(element["price_components"]),
        is_map(component),
        component["type"] == "ENERGY",
        net = euro_millis(component["price"]),
        is_integer(net) do
      %{
        net: net,
        vat: vat_percent(component["vat"]),
        max_kw: kw_limit(restrictions["max_power"]),
        min_kw: kw_limit(restrictions["min_power"]),
        start: clock_minute(restrictions["start_time"]),
        stop: clock_minute(restrictions["end_time"]),
        days: weekdays(restrictions["day_of_week"])
      }
    end
  end

  defp energy_rates(_tariffs), do: []

  @weekdays ~w(MONDAY TUESDAY WEDNESDAY THURSDAY FRIDAY SATURDAY SUNDAY)

  defp weekdays(names) when is_list(names) do
    names
    |> Enum.map(fn name ->
      Enum.find_index(@weekdays, &(String.upcase(to_string(name)) == &1))
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 + 1))
    |> case do
      [] -> nil
      days -> days
    end
  end

  defp weekdays(_names), do: nil

  defp clock_minute(text) when is_binary(text) do
    case Regex.run(~r/\A(\d{1,2}):(\d{2})/, String.trim(text)) do
      [_, hour, minute] ->
        hour = String.to_integer(hour)
        minute = String.to_integer(minute)
        if hour in 0..24 and minute in 0..59, do: hour * 60 + minute, else: nil

      _ ->
        nil
    end
  end

  defp clock_minute(_text), do: nil

  defp euro_millis(value) do
    case decimal(value) do
      price when is_number(price) and price >= 0 and price <= 5 -> round(price * 1000)
      _ -> nil
    end
  end

  defp vat_percent(value) do
    case decimal(value) do
      percent when is_number(percent) and percent >= 0 and percent <= 100 -> round(percent)
      _ -> nil
    end
  end

  defp kw_limit(value) do
    case decimal(value) do
      kw when is_number(kw) and kw > 0 -> kw / 1
      _ -> nil
    end
  end

  defp decimal(value) when is_float(value), do: value
  defp decimal(value) when is_integer(value), do: value

  defp decimal(value) when is_binary(value) do
    case Float.parse(String.replace(String.trim(value), ",", ".")) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp decimal(_value), do: nil

  defp coordinates(%{"latitude" => latitude, "longitude" => longitude}) do
    {coordinate(latitude), coordinate(longitude)}
  end

  defp coordinates(_coordinates), do: {nil, nil}

  defp coordinate(value) when is_float(value), do: value
  defp coordinate(value) when is_integer(value), do: value / 1

  defp coordinate(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", ".")) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp coordinate(_value), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
