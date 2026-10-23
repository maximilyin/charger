defmodule Charger.Chargers.Tariff do
  @moduledoc """
  The energy price to show for a Reve connector.

  A tariff lists several energy prices. Each one may apply only up to a
  connector power and only during some hours. The price shown is the band
  that covers this connector, at the current time in Spain. VAT is added when
  the tariff states it. Prices are thousandths of a euro.
  """

  def for_connector(connector, %DateTime{} = at) do
    madrid = Charger.Prices.Schedule.to_madrid(at)

    for_connector(
      connector,
      Date.day_of_week(DateTime.to_date(madrid)),
      madrid.hour * 60 + madrid.minute
    )
  end

  def for_connector(%{rates: rates} = connector, day, minute)
      when is_list(rates) and day in 1..7 and is_integer(minute) do
    rates
    |> band(connector[:power_kw])
    |> current(day, minute)
    |> Enum.map(&gross/1)
    |> span()
  end

  def for_connector(_connector, _day, _minute), do: nil

  def merge(nil, nil), do: nil
  def merge(nil, price), do: price
  def merge(price, nil), do: price

  def merge(%{min: left_min, max: left_max}, %{min: right_min, max: right_max}) do
    %{min: min(left_min, right_min), max: max(left_max, right_max)}
  end

  # The tightest power cap that still covers this connector. A 7 kW plug then
  # takes the "up to 22 kW" price, not the fast-charger price in the same tariff.
  defp band(rates, kw) when is_number(kw) do
    covering =
      Enum.filter(rates, fn rate ->
        (is_nil(rate.max_kw) or kw <= rate.max_kw) and
          (is_nil(rate.min_kw) or kw >= rate.min_kw)
      end)

    case Enum.filter(covering, &is_number(&1.max_kw)) do
      [] ->
        covering

      limited ->
        cap = limited |> Enum.map(& &1.max_kw) |> Enum.min()
        Enum.filter(limited, &(&1.max_kw == cap))
    end
  end

  defp band(rates, _kw), do: rates

  defp current(rates, day, minute) do
    case Enum.filter(rates, &applies?(&1, day, minute)) do
      [] -> rates
      matching -> matching
    end
  end

  defp applies?(rate, day, minute) do
    (is_nil(rate.days) or day in rate.days) and time?(rate.start, rate.stop, minute)
  end

  defp time?(nil, nil, _minute), do: true

  defp time?(start, stop, minute) when is_integer(start) and is_integer(stop) and start <= stop do
    minute >= start and minute <= stop
  end

  defp time?(start, stop, minute) when is_integer(start) and is_integer(stop) do
    minute >= start or minute <= stop
  end

  defp time?(_start, _stop, _minute), do: true

  defp gross(%{net: net, vat: nil}), do: net
  defp gross(%{net: net, vat: vat}) when is_integer(vat), do: round(net * (100 + vat) / 100)

  defp span([]), do: nil
  defp span(prices), do: %{min: Enum.min(prices), max: Enum.max(prices)}
end
