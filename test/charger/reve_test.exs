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

  test "requests continue until the limit error, then wait" do
    :persistent_term.put(@script, fn
      1 -> {:ok, Enum.map(1..100, &%{"id" => "L#{&1}"})}
      2 -> {:error, :rate_limited}
      page -> {:error, {:unexpected, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.status == :waiting and snap.count == 100 end)

    assert snapshot.next_page == 2
    assert snapshot.complete == false
    assert snapshot.error == nil

    {:ok, json, updated_at} = Charger.CacheFile.read(path())
    assert %DateTime{} = updated_at

    assert {:ok, %{"next_page" => 2, "complete" => false, "locations" => locations}} =
             Jason.decode(json)

    assert map_size(locations) == 100
    assert locations["L1"]["id"] == "L1"
  end

  test "a request error keeps the same page and does not retry immediately" do
    counter = :counters.new(1, [:atomics])

    :persistent_term.put(@script, fn
      1 ->
        :counters.add(counter, 1, 1)
        {:error, :timeout}

      page ->
        {:error, {:unexpected, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.error != nil end)

    assert snapshot.next_page == 1
    assert snapshot.count == 0
    assert snapshot.status == :waiting
    Process.sleep(50)
    assert :counters.get(counter, 1) == 1
  end

  test "a short page finishes the catalog and the file keeps every location" do
    :persistent_term.put(@script, fn
      1 -> {:ok, [%{"id" => "a", "city" => "Madrid"}, %{"id" => "b", "city" => "Valencia"}]}
      page -> {:error, {:unexpected, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.complete end)

    assert snapshot.status == :complete
    assert snapshot.count == 2
    assert snapshot.next_page == 2
    assert Enum.map(snapshot.locations, & &1["id"]) |> Enum.sort() == ["a", "b"]
  end

  test "a later field stays on the same station id" do
    :persistent_term.put(@script, fn
      1 ->
        {:ok,
         Enum.map(1..99, &%{"id" => "L#{&1}"}) ++
           [%{"id" => "a", "city" => "Madrid", "prices" => [%{"price" => 0.4}]}]}

      2 ->
        {:ok, [%{"id" => "a", "city" => "Barcelona"}]}

      page ->
        {:error, {:unexpected, page}}
    end)

    send(ChargerReve, :fetch)
    snapshot = await(fn snap -> snap.complete end)
    location = Enum.find(snapshot.locations, &(&1["id"] == "a"))

    assert location["city"] == "Barcelona"
    assert location["prices"] == [%{"price" => 0.4}]

    {:ok, json, _updated_at} = Charger.CacheFile.read(path())
    assert {:ok, %{"locations" => %{"a" => stored}}} = Jason.decode(json)
    assert stored["city"] == "Barcelona"
    assert stored["prices"] == [%{"price" => 0.4}]
  end

  test "a restart continues from the saved page and still asks the API" do
    body =
      Jason.encode!(%{
        "next_page" => 3,
        "complete" => false,
        "locations" => %{"a" => %{"id" => "a", "city" => "Madrid"}}
      })

    assert :ok = Charger.CacheFile.write(path(), body, ~U[2026-10-05 12:00:00Z])

    :persistent_term.put(@script, fn
      3 -> {:ok, [%{"id" => "b", "city" => "Valencia"}]}
      page -> {:error, {:unexpected, page}}
    end)

    restart(ChargerReve)
    snapshot = await(fn snap -> snap.complete and snap.count == 2 end)

    assert snapshot.next_page == 4
    assert Enum.map(snapshot.locations, & &1["id"]) |> Enum.sort() == ["a", "b"]
    assert snapshot.updated_at != ~U[2026-10-05 12:00:00Z]
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
    pid = Process.whereis(module)
    ref = Process.monitor(pid)
    assert :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    new_pid =
      Enum.find_value(1..100, fn _ ->
        Process.sleep(10)

        case Process.whereis(module) do
          ^pid -> nil
          nil -> nil
          other -> other
        end
      end)

    assert is_pid(new_pid)
  end
end
