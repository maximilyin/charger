defmodule Charger.Chargers.TariffTest do
  use ExUnit.Case, async: true

  alias Charger.Chargers.Tariff

  # 15 Jan 2026 12:00 UTC is 13:00 in Spain (winter).
  @afternoon ~U[2026-01-15 12:00:00Z]
  @night ~U[2026-01-15 22:30:00Z]

  test "a plain energy price is shown as it is when the tariff states no VAT" do
    connector = connector(50, [rate(400, nil)])

    assert Tariff.for_connector(connector, @afternoon) == %{min: 400, max: 400}
    assert Charger.Chargers.format_tariff(%{min: 400, max: 400}, "uk") == "0,400 €"
    assert Charger.Chargers.format_tariff(%{min: 351, max: 569}, "uk") == "0,351–0,569 €"
    assert Charger.Chargers.format_tariff(%{min: 400, max: 400}, "en") == "€0.400"
  end

  test "VAT is added and the power band for this connector is chosen" do
    connector =
      connector(6.9, [
        rate(290, 21, 22.0, 7 * 60, 22 * 60 + 59),
        rate(250, 21, 22.0, 23 * 60, 6 * 60 + 59),
        rate(470, 21, 450.0, 7 * 60, 22 * 60 + 59)
      ])

    assert Tariff.for_connector(connector, @afternoon) == %{min: 351, max: 351}
    assert Tariff.for_connector(connector, @night) == %{min: 303, max: 303}

    assert Tariff.for_connector(connector(150, connector.rates), @afternoon) == %{
             min: 569,
             max: 569
           }
  end

  test "prices of the same plug are joined into one range" do
    assert Tariff.merge(%{min: 300, max: 300}, %{min: 450, max: 500}) == %{min: 300, max: 500}
    assert Tariff.merge(nil, %{min: 300, max: 300}) == %{min: 300, max: 300}
  end

  defp connector(kw, rates), do: %{power_kw: kw, rates: rates}

  defp rate(net, vat, max_kw \\ nil, start \\ nil, stop \\ nil) do
    %{net: net, vat: vat, max_kw: max_kw, min_kw: nil, start: start, stop: stop, days: nil}
  end
end
