defmodule Charger.Geo do
  @moduledoc false

  @earth_m 6_371_000

  def distance_m({lat1, lon1}, {lat2, lon2})
      when is_number(lat1) and is_number(lon1) and is_number(lat2) and is_number(lon2) do
    phi1 = degrees(lat1)
    phi2 = degrees(lat2)
    dphi = degrees(lat2 - lat1)
    dlambda = degrees(lon2 - lon1)

    haversine =
      :math.sin(dphi / 2) * :math.sin(dphi / 2) +
        :math.cos(phi1) * :math.cos(phi2) * :math.sin(dlambda / 2) * :math.sin(dlambda / 2)

    2 * @earth_m * :math.asin(min(1.0, :math.sqrt(haversine)))
  end

  def distance_m(point, latitude, longitude) when is_number(latitude) and is_number(longitude) do
    case coordinates(point) do
      nil -> nil
      pair -> distance_m(pair, {latitude, longitude})
    end
  end

  def distance_m(_point, _latitude, _longitude), do: nil

  defp coordinates(%{latitude: latitude, longitude: longitude}) do
    case {number(latitude), number(longitude)} do
      {{lat, _lat_rest}, {lng, _lng_rest}} -> {lat, lng}
      _ -> nil
    end
  end

  defp coordinates(_point), do: nil

  defp number(value) when is_float(value), do: {value, ""}
  defp number(value) when is_integer(value), do: {value / 1, ""}
  defp number(value) when is_binary(value), do: Float.parse(value)
  defp number(_value), do: :error

  defp degrees(value), do: value * :math.pi() / 180
end
