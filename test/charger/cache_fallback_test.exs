defmodule Charger.CacheFallbackTest do
  use ExUnit.Case, async: false

  setup do
    prices = Application.get_env(:charger, Charger.Prices.Cache)
    chargers = Application.get_env(:charger, Charger.Chargers.Cache)

    on_exit(fn ->
      Application.put_env(:charger, Charger.Prices.Cache, prices)
      Application.put_env(:charger, Charger.Chargers.Cache, chargers)
      Charger.Prices.Cache.refresh_now()
      Charger.Chargers.Cache.refresh_now()
    end)

    :ok
  end

  test "fuel cache still calls the API, restores an empty table from the file, and keeps a filled table" do
    path = cache_path(Charger.Prices.Cache)
    use_source(Charger.Prices.Cache, Charger.Prices.FixtureSource)
    Charger.Prices.Cache.refresh_now()

    saved = Charger.Prices.Cache.snapshot()
    assert saved.status == :ready
    assert saved.stations != []

    assert {:ok, json, updated_at} = Charger.CacheFile.read(path)
    assert updated_at == saved.fetched_at
    assert {:ok, %{"Fecha" => "02/10/2026 8:36:47"}} = Jason.decode(json)
    original = File.read!(path)

    use_source(Charger.Prices.Cache, Charger.DownSource)
    calls = Charger.DownSource.fetch_count()

    Charger.Prices.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 1

    kept = Charger.Prices.Cache.snapshot()
    assert kept.stations == saved.stations
    assert kept.fetched_at == updated_at
    assert File.read!(path) == original

    GenServer.call(Charger.Prices.Cache, :clear)
    assert Charger.Prices.Cache.snapshot().stations == []

    Charger.Prices.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 2

    restored = Charger.Prices.Cache.snapshot()
    assert restored.status == :ready
    assert restored.stations == saved.stations
    assert restored.fetched_at == updated_at
    assert File.read!(path) == original

    Charger.Prices.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 3
    assert Charger.Prices.Cache.snapshot().stations == saved.stations
    assert Charger.Prices.Cache.snapshot().fetched_at == updated_at
    assert File.read!(path) == original

    restart(Charger.Prices.Cache)
    await_fetches(calls + 4)

    started = Charger.Prices.Cache.snapshot()
    assert started.status == :ready
    assert started.stations == saved.stations
    assert started.fetched_at == updated_at
    assert File.read!(path) == original
  end

  test "a fuel refresh with no file and no API leaves ETS empty" do
    path = cache_path(Charger.Prices.Cache)
    File.rm(path)
    GenServer.call(Charger.Prices.Cache, :clear)
    use_source(Charger.Prices.Cache, Charger.DownSource)

    Charger.Prices.Cache.refresh_now()

    snapshot = Charger.Prices.Cache.snapshot()
    assert snapshot.status == :error
    assert snapshot.stations == []
    refute File.exists?(path)
  end

  test "charger cache still calls the API, restores an empty table from the file, and keeps a filled table" do
    path = cache_path(Charger.Chargers.Cache)
    use_source(Charger.Chargers.Cache, Charger.Chargers.FixtureSource)
    Charger.Chargers.Cache.refresh_now()

    saved = Charger.Chargers.Cache.snapshot()
    assert saved.status == :ready
    assert saved.sites != []

    assert {:ok, csv, updated_at} = Charger.CacheFile.read(path)
    assert updated_at == saved.fetched_at
    assert String.starts_with?(csv, "COMUNIDAD AUTONOMA;")
    original = File.read!(path)

    use_source(Charger.Chargers.Cache, Charger.DownSource)
    calls = Charger.DownSource.fetch_count()

    Charger.Chargers.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 1

    kept = Charger.Chargers.Cache.snapshot()
    assert kept.sites == saved.sites
    assert kept.fetched_at == updated_at
    assert File.read!(path) == original

    GenServer.call(Charger.Chargers.Cache, :clear)
    assert Charger.Chargers.Cache.snapshot().sites == []

    Charger.Chargers.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 2

    restored = Charger.Chargers.Cache.snapshot()
    assert restored.status == :ready
    assert restored.sites == saved.sites
    assert restored.fetched_at == updated_at
    assert File.read!(path) == original

    Charger.Chargers.Cache.refresh_now()
    assert Charger.DownSource.fetch_count() == calls + 3
    assert Charger.Chargers.Cache.snapshot().sites == saved.sites
    assert Charger.Chargers.Cache.snapshot().fetched_at == updated_at
    assert File.read!(path) == original

    restart(Charger.Chargers.Cache)
    await_fetches(calls + 4)

    started = Charger.Chargers.Cache.snapshot()
    assert started.status == :ready
    assert started.sites == saved.sites
    assert started.fetched_at == updated_at
    assert File.read!(path) == original
  end

  defp cache_path(module) do
    Application.get_env(:charger, module) |> Keyword.fetch!(:path)
  end

  defp use_source(module, source) do
    config = Application.get_env(:charger, module) |> Keyword.put(:source, source)
    Application.put_env(:charger, module, config)
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

  defp await_fetches(at_least) do
    Enum.reduce_while(1..100, Charger.DownSource.fetch_count(), fn _, count ->
      if count >= at_least do
        {:halt, count}
      else
        Process.sleep(10)
        {:cont, Charger.DownSource.fetch_count()}
      end
    end)
    |> then(fn count -> assert count >= at_least end)
  end
end
