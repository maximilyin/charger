defmodule Charger.Chargers.Cache do
  @moduledoc """
  ETS snapshot of the public charging catalog.

  This process is the only one that downloads the RIPREE file. It refreshes
  on startup and then once a day. Pages only read the table.

  Each successful response is written to disk after ETS. The first line of
  that file is the update time. If the download fails, the file fills ETS,
  and the following refresh still downloads RIPREE.
  """

  use GenServer
  require Logger

  @table :charger_chargers

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    if :ets.whereis(@table) == :undefined do
      empty()
    else
      case :ets.lookup(@table, :snapshot) do
        [{:snapshot, snapshot}] -> snapshot
        [] -> empty()
      end
    end
  end

  def refresh_now do
    GenServer.call(__MODULE__, :refresh, 180_000)
  end

  @impl true
  def init(_opts) do
    create_table()
    load_file()
    Phoenix.PubSub.subscribe(Charger.PubSub, "prices")
    send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    Process.send_after(self(), :refresh, interval_ms())
    {:noreply, state}
  end

  def handle_info(:updated, state) do
    recompute_overlap()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    refresh()
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.insert(@table, {:snapshot, empty()})
    {:reply, :ok, state}
  end

  def interval_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:interval_ms, :timer.hours(24))
  end

  defp refresh do
    case source().fetch() do
      {:ok, payload} ->
        updated_at = DateTime.utc_now() |> DateTime.truncate(:second)
        store(payload, updated_at, "api")
        write_file(payload, updated_at)

      {:error, reason} ->
        Logger.error("charger catalog refresh failed: #{inspect(reason)}")
        current = snapshot()

        cond do
          current.sites != [] ->
            :ets.insert(@table, {:snapshot, %{current | error: inspect(reason)}})

          load_file() == :ok ->
            :ok

          true ->
            :ets.insert(@table, {:snapshot, %{empty() | status: :error, error: inspect(reason)}})
        end
    end
  end

  defp store(payload, updated_at, origin) do
    parsed = Charger.Chargers.Parser.parse(payload)
    fuel = Charger.Prices.Cache.snapshot().stations

    snapshot = %{
      status: :ready,
      sites: parsed.sites,
      overlap: Charger.Chargers.Overlap.report(fuel, parsed.sites),
      fetched_at: updated_at,
      error: nil
    }

    :ets.insert(@table, {:snapshot, snapshot})
    log_overlap(snapshot, origin, updated_at)
    Phoenix.PubSub.broadcast(Charger.PubSub, "chargers", :updated)
    :ok
  end

  defp write_file(payload, updated_at) when is_binary(payload) do
    case Charger.CacheFile.write(file_path(), payload, updated_at) do
      :ok -> :ok
      {:error, reason} -> Logger.error("charger catalog file write failed: #{inspect(reason)}")
    end
  end

  defp load_file do
    case Charger.CacheFile.read(file_path()) do
      {:ok, payload, updated_at} ->
        store(payload, updated_at, "file")

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        Logger.error("charger catalog file unreadable: #{inspect(reason)}")
        :empty
    end
  end

  defp file_path do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get_lazy(:path, fn ->
      :charger |> :code.priv_dir() |> to_string() |> Path.join("cache/chargers.csv")
    end)
  end

  defp recompute_overlap do
    current = snapshot()

    if current.sites != [] do
      fuel = Charger.Prices.Cache.snapshot().stations
      overlap = Charger.Chargers.Overlap.report(fuel, current.sites)

      if overlap != current.overlap do
        updated = %{current | overlap: overlap}
        :ets.insert(@table, {:snapshot, updated})
        log_overlap(updated, "overlap", updated.fetched_at)
      end
    end
  end

  defp log_overlap(%{sites: sites, overlap: overlap}, origin, updated_at) do
    Logger.info(
      "charger catalog from #{origin}: #{length(sites)} sites, " <>
        "updated_at=#{DateTime.to_iso8601(updated_at)}; " <>
        "fuel overlap 30m=#{overlap.within_30m} 50m=#{overlap.within_50m} " <>
        "80m=#{overlap.within_80m} address=#{overlap.same_address}"
    )
  end

  defp source do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:source, Charger.Chargers.Ripree)
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    end
  end

  defp empty do
    %{
      status: :loading,
      sites: [],
      overlap: nil,
      fetched_at: nil,
      error: nil
    }
  end
end
