defmodule Charger.ReveTest do
  use ExUnit.Case, async: false

  @script {Charger.Reve.ScriptedSource, :script}

  setup do
    on_exit(fn ->
      :persistent_term.erase(@script)

      if Process.whereis(ChargerReve) do
        GenServer.call(ChargerReve, :reset)
      end
    end)

    GenServer.call(ChargerReve, :reset)
    :ok
  end

  test "a limit response is recognized without treating other errors as the limit" do
    assert {:error, :rate_limited} =
             ChargerReve.classify(429, %{"message" => "busy"})

    assert {:error, :rate_limited} =
             ChargerReve.classify(403, "Se ha superado el límite de solicitudes")

    assert {:error, {:http, 500}} = ChargerReve.classify(500, "down")
    assert {:ok, []} = ChargerReve.classify(200, [])

    request = Req.new(method: :get)
    refute ChargerReve.retry?(request, %Req.Response{status: 429})
    assert ChargerReve.retry?(request, %Req.Response{status: 500})
    assert ChargerReve.retry?(request, %Req.TransportError{reason: :timeout})
    refute ChargerReve.retry?(request, %Req.Response{status: 404})
  end

  test "five successful pages wait an hour before the next page" do
    counter = :counters.new(1, [:atomics])

    script(fn kind, page ->
      :counters.add(counter, 1, 1)

      case {kind, page} do
        {:cpos, 1} -> {:ok, [%{"party_id" => "AAA"}]}
        {{:locations, "AAA"}, page} when page in 1..4 -> {:ok, full_page("AAA", page)}
        other -> {:error, {:unexpected, other}}
      end
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.status == :waiting and snap.count == 400 end)

    assert snapshot.operator == "AAA"
    assert snapshot.operator_page == 5
    assert snapshot.complete == false
    assert snapshot.error == nil
    Process.sleep(50)
    assert :counters.get(counter, 1) == 5
  end

  test "requests continue until the limit error, then wait" do
    script(fn
      :cpos, 1 -> {:ok, [%{"party_id" => "AAA"}]}
      {:locations, "AAA"}, 1 -> {:ok, full_page("AAA", 1)}
      {:locations, "AAA"}, 2 -> {:error, :rate_limited}
      kind, page -> {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.status == :waiting and snap.count == 100 end)

    assert snapshot.operator_page == 2
    assert snapshot.complete == false
    assert snapshot.error == nil

    {:ok, json, updated_at} = Charger.CacheFile.read(path())
    assert %DateTime{} = updated_at
    assert {:ok, body} = Jason.decode(json)
    assert body["operators"] == ["AAA"]
    assert body["operator_page"] == 2
    assert body["cpos_complete"] == true
    assert map_size(body["locations"]) == 100
    assert body["locations"]["AAA-1-1"]["id"] == "AAA-1-1"
  end

  test "a request error keeps the same page and does not retry immediately" do
    counter = :counters.new(1, [:atomics])

    script(fn
      :cpos, 1 ->
        :counters.add(counter, 1, 1)
        {:error, :timeout}

      kind, page ->
        {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.error != nil end)

    assert snapshot.cpo_page == 1
    assert snapshot.count == 0
    assert snapshot.status == :waiting
    Process.sleep(50)
    assert :counters.get(counter, 1) == 1
  end

  test "operators are collected one by one, then the tariffs" do
    script(fn
      :cpos, 1 -> {:ok, [%{"party_id" => "AAA"}, %{"party_id" => "BBB"}]}
      {:locations, "AAA"}, 1 -> {:ok, [%{"id" => "a", "party_id" => "AAA"}]}
      {:locations, "BBB"}, 1 -> {:ok, [%{"id" => "b", "party_id" => "BBB"}]}
      :tariffs, 1 -> {:ok, []}
      kind, page -> {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.tariffs_complete end)

    assert snapshot.status == :complete
    assert snapshot.complete
    assert snapshot.operators_complete
    assert snapshot.operators_left == 0
    assert snapshot.count == 2
    assert snapshot.tariff_page == 2
    assert snapshot.locations |> Enum.map(& &1["id"]) |> Enum.sort() == ["a", "b"]
  end

  test "a station already stored is not written again" do
    script(fn
      :cpos, 1 ->
        {:ok, [%{"party_id" => "AAA"}, %{"party_id" => "BBB"}]}

      {:locations, "AAA"}, 1 ->
        {:ok, [%{"id" => "a", "party_id" => "AAA", "city" => "Madrid"}]}

      {:locations, "BBB"}, 1 ->
        {:ok,
         [
           %{"id" => "a", "party_id" => "AAA", "city" => "Barcelona"},
           %{"id" => "b", "party_id" => "BBB", "city" => "Valencia"}
         ]}

      kind, page ->
        {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.operators_complete end)

    assert snapshot.count == 2
    assert Enum.find(snapshot.locations, &(&1["id"] == "a"))["city"] == "Madrid"

    {:ok, json, _updated_at} = Charger.CacheFile.read(path())
    assert {:ok, %{"locations" => %{"a" => stored} = locations}} = Jason.decode(json)
    assert map_size(locations) == 2
    assert stored["city"] == "Madrid"
  end

  test "a tariff is stored on its connector inside the station" do
    tariff = tariff("T1")

    script(fn
      :cpos, 1 ->
        {:ok, [%{"party_id" => "REP"}]}

      {:locations, "REP"}, 1 ->
        {:ok, [location("a", [connector("c1", 50_000), connector("c2", 22_000)])]}

      :tariffs, 1 ->
        {:ok,
         [
           %{"connector_id" => "c1", "evse_id" => "E1", "tariffs" => [tariff]},
           %{"connector_id" => "zz", "evse_id" => "E9", "tariffs" => [tariff]}
         ]}

      kind, page ->
        {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.tariffs_complete end)

    [stored] = snapshot.locations
    [evse] = stored["evses"]
    connectors = Map.new(evse["connectors"], &{&1["id"], &1})

    assert connectors["c1"]["tariffs"] == [tariff]
    refute Map.has_key?(connectors["c2"], "tariffs")
    assert connectors["c1"]["max_electric_power"] == 50_000
    assert snapshot.unmatched_tariffs == 1

    {:ok, json, _updated_at} = Charger.CacheFile.read(path())
    assert {:ok, body} = Jason.decode(json)
    assert body["tariffs_complete"] == true
    assert Map.keys(body["unmatched_tariffs"]) == ["zz"]

    assert [%{"id" => "c1", "tariffs" => [_]} | _] =
             body["locations"]["a"]["evses"] |> hd() |> Map.fetch!("connectors")
  end

  test "a waiting tariff is attached when its station arrives" do
    tariff = %{"connector_id" => "c9", "tariffs" => [tariff("T9")]}

    write_body(%{
      "complete" => true,
      "cpos_complete" => true,
      "operators" => ["BBB"],
      "operator_page" => 1,
      "tariff_page" => 2,
      "tariffs_complete" => true,
      "locations" => %{"a" => location("a", [connector("c1", 50_000)])},
      "unmatched_tariffs" => %{"c9" => tariff}
    })

    script(fn
      {:locations, "BBB"}, 1 -> {:ok, [location("b", [connector("c9", 7_400)], "BBB")]}
      kind, page -> {:error, {:unexpected, kind, page}}
    end)

    restart(ChargerReve)
    snapshot = await(fn snap -> snap.status == :complete end)

    b = Enum.find(snapshot.locations, &(&1["id"] == "b"))
    assert [%{"id" => "c9", "tariffs" => [%{"id" => "T9"}]}] = hd(b["evses"])["connectors"]
    assert snapshot.unmatched_tariffs == 0
    assert snapshot.count == 2
  end

  test "an old file keeps its stations and collects known operators first" do
    test_pid = self()

    write_body(%{
      "next_page" => 149,
      "complete" => true,
      "tariff_page" => 6,
      "tariffs_complete" => false,
      "locations" => %{"a" => %{"id" => "a", "party_id" => "IBD", "city" => "Madrid"}},
      "unmatched_tariffs" => %{}
    })

    script(fn kind, page ->
      send(test_pid, {:called, kind, page})

      case {kind, page} do
        {:cpos, 1} -> {:ok, [%{"party_id" => "NEW"}, %{"party_id" => "IBD"}]}
        {{:locations, "IBD"}, 1} -> {:ok, [%{"id" => "a", "party_id" => "IBD", "city" => "X"}]}
        {{:locations, "NEW"}, 1} -> {:ok, [%{"id" => "n", "party_id" => "NEW"}]}
        {:tariffs, 6} -> {:ok, []}
        other -> {:error, {:unexpected, other}}
      end
    end)

    restart(ChargerReve)
    snapshot = await(fn snap -> snap.status == :complete end)

    assert_receive {:called, :cpos, 1}
    assert_receive {:called, {:locations, "IBD"}, 1}
    assert_receive {:called, {:locations, "NEW"}, 1}
    assert_receive {:called, :tariffs, 6}

    assert snapshot.count == 2
    assert snapshot.tariff_page == 7
    assert Enum.find(snapshot.locations, &(&1["id"] == "a"))["city"] == "Madrid"
    assert ChargerReve.catalog().sites |> Enum.map(& &1.id) |> Enum.sort() == ["a", "n"]
  end

  test "a restart continues the current operator from the saved page" do
    test_pid = self()

    write_body(%{
      "complete" => false,
      "cpos_complete" => true,
      "operators" => ["AAA", "BBB"],
      "operator_page" => 3,
      "locations" => %{"a" => %{"id" => "a", "party_id" => "AAA"}}
    })

    script(fn kind, page ->
      send(test_pid, {:called, kind, page})

      case {kind, page} do
        {{:locations, "AAA"}, 3} -> {:ok, [%{"id" => "x", "party_id" => "AAA"}]}
        {{:locations, "BBB"}, 1} -> {:ok, []}
        {:tariffs, 1} -> {:ok, []}
        other -> {:error, {:unexpected, other}}
      end
    end)

    restart(ChargerReve)
    snapshot = await(fn snap -> snap.status == :complete end)

    assert_receive {:called, {:locations, "AAA"}, 3}
    refute_received {:called, :cpos, _}
    assert snapshot.count == 2
    assert snapshot.complete
  end

  test "a complete location list replaces RIPREE in the charging catalog" do
    assert ChargerReve.catalog() == nil
    assert Enum.any?(Charger.Chargers.snapshot().sites, &(&1.id == "SITE-A"))

    script(fn
      :cpos, 1 ->
        {:ok, [%{"party_id" => "REP"}]}

      {:locations, "REP"}, 1 ->
        {:ok,
         [
           location("a", [connector("c1", 150_000), connector("c2", 22_000, "AC_3_PHASE")])
           |> Map.merge(%{"city" => "MADRID", "city_code" => "079", "region" => "28"}),
           location("b", [connector("c3", 7_400, "AC_1_PHASE")])
           |> Map.merge(%{"city" => "Madrid", "city_code" => "079", "region" => "28"})
         ]}

      kind, page ->
        {:error, {:unexpected, kind, page}}
    end)

    send(ChargerReve, :fetch)
    await(fn snap -> snap.complete end)

    result = Charger.Chargers.query(%{"take" => 10})

    assert result.total == 2
    assert result.provinces == ["Madrid"]
    assert result.municipalities == ["Madrid"]

    assert [%{id: "a", price: 150_000, brand: "REPSOL"}, %{id: "b", price: 7_400}] =
             result.stations

    refute Enum.any?(Charger.Chargers.snapshot().sites, &(&1.id == "SITE-A"))
  end

  defp script(fun), do: :persistent_term.put(@script, fun)

  defp full_page(party_id, page) do
    Enum.map(1..100, &%{"id" => "#{party_id}-#{page}-#{&1}", "party_id" => party_id})
  end

  defp write_body(body) do
    assert :ok = Charger.CacheFile.write(path(), Jason.encode!(body), ~U[2026-10-05 12:00:00Z])
  end

  defp tariff(id) do
    %{
      "id" => id,
      "currency" => "EUR",
      "elements" => [%{"price_components" => [%{"type" => "ENERGY", "price" => "0.45"}]}]
    }
  end

  defp location(id, connectors, party_id \\ "REP") do
    %{
      "id" => id,
      "party_id" => party_id,
      "name" => "Estación #{id}",
      "cpo_name" => "REPSOL SOLUCIONES ENERGÉTICAS SA",
      "address" => "Calle Mayor 1",
      "city" => "Madrid",
      "region" => "28",
      "state" => "13",
      "postal_code" => "28013",
      "coordinates" => %{"latitude" => "40.4168", "longitude" => "-3.7038"},
      "opening_times" => %{"twentyfourseven" => true},
      "evses" => [%{"evse_id" => "ES*X*E#{id}", "connectors" => connectors}]
    }
  end

  defp connector(id, watts, power_type \\ "DC") do
    %{
      "id" => id,
      "standard" => "IEC_62196_T2_COMBO",
      "power_type" => power_type,
      "max_electric_power" => watts
    }
  end

  defp path do
    Application.get_env(:charger, ChargerReve) |> Keyword.fetch!(:path)
  end

  defp await(fun) do
    Enum.reduce_while(1..50, ChargerReve.snapshot(), fn _, snapshot ->
      if fun.(snapshot) do
        {:halt, snapshot}
      else
        Process.sleep(20)
        {:cont, ChargerReve.snapshot()}
      end
    end)
    |> tap(fn snapshot ->
      assert fun.(snapshot)
    end)
  end

  defp restart(module) do
    assert :ok = Supervisor.terminate_child(Charger.Supervisor, module)
    assert {:ok, pid} = Supervisor.restart_child(Charger.Supervisor, module)
    assert Process.whereis(module) == pid
  end
end
