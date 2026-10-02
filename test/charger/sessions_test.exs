defmodule Charger.SessionsTest do
  use ExUnit.Case, async: true

  test "creates a session and keeps its filters" do
    id = Charger.Sessions.new_id()
    filters = Charger.Sessions.ensure(id)

    assert filters == Charger.Sessions.default_filters()

    :ok =
      Charger.Sessions.put(id, %{
        province: "MADRID",
        municipality: "",
        fuel: "diesel_a",
        q: "cepsa"
      })

    assert {:ok, stored} = Charger.Sessions.fetch(id)
    assert stored.province == "MADRID"
    assert stored.fuel == "diesel_a"
    assert stored.q == "cepsa"

    [{^id, ^stored, expires_at}] = :ets.lookup(:charger_sessions, id)
    assert expires_at > System.system_time(:second) + 23 * 60 * 60
  end

  test "sweep drops sessions whose lifetime has passed" do
    id = Charger.Sessions.new_id()
    Charger.Sessions.put(id, Charger.Sessions.default_filters())

    :ets.insert(
      :charger_sessions,
      {id, Charger.Sessions.default_filters(), System.system_time(:second) - 1}
    )

    assert Charger.Sessions.sweep() >= 1
    assert Charger.Sessions.fetch(id) == :miss
  end
end
