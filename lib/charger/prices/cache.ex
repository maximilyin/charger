defmodule Charger.Prices.Cache do
  @moduledoc """
  ETS snapshot of fuel prices.

  This process is the only one that calls the ministry. It refreshes on
  startup and then every hour. Web requests only read the table.

  Each successful response is written to disk after ETS. The first line of
  that file is the update time. If the ministry is down, the file fills ETS,
  and the following refresh still calls the ministry.
  """

  use GenServer
  require Logger

  @table :charger_prices
  @topic "prices"

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
    GenServer.call(__MODULE__, :refresh, 120_000)
  end

  @impl true
  def init(_opts) do
    create_table()
    load_file()
    send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    Process.send_after(self(), :refresh, interval_ms())
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
    |> Keyword.get(:interval_ms, :timer.hours(1))
  end

  defp refresh do
    case source().fetch() do
      {:ok, payload} ->
        updated_at = DateTime.utc_now() |> DateTime.truncate(:second)
        store(payload, updated_at, "api")
        write_file(payload, updated_at)

      {:error, reason} ->
        Logger.error("fuel price refresh failed: #{inspect(reason)}")
        current = snapshot()

        cond do
          current.stations != [] ->
            :ets.insert(@table, {:snapshot, %{current | error: inspect(reason)}})
            Phoenix.PubSub.broadcast(Charger.PubSub, @topic, :updated)

          load_file() == :ok ->
            :ok

          true ->
            :ets.insert(@table, {:snapshot, %{empty() | status: :error, error: inspect(reason)}})
            Phoenix.PubSub.broadcast(Charger.PubSub, @topic, :updated)
        end
    end
  end

  defp store(payload, updated_at, origin) do
    snapshot =
      payload
      |> Charger.Prices.Parser.parse()
      |> Map.put(:status, :ready)
      |> Map.put(:error, nil)
      |> Map.put(:fetched_at, updated_at)

    :ets.insert(@table, {:snapshot, snapshot})

    Logger.info(
      "fuel price cache from #{origin}: #{length(snapshot.stations)} stations, " <>
        "updated_at=#{DateTime.to_iso8601(updated_at)}"
    )

    Phoenix.PubSub.broadcast(Charger.PubSub, @topic, :updated)
    :ok
  end

  defp write_file(payload, updated_at) do
    case Jason.encode(payload) do
      {:ok, json} ->
        case Charger.CacheFile.write(file_path(), json, updated_at) do
          :ok -> :ok
          {:error, reason} -> Logger.error("fuel price file write failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("fuel price file encode failed: #{inspect(reason)}")
    end
  end

  defp load_file do
    case Charger.CacheFile.read(file_path()) do
      {:ok, json, updated_at} ->
        case Jason.decode(json) do
          {:ok, payload} when is_map(payload) -> store(payload, updated_at, "file")
          _ -> :empty
        end

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        Logger.error("fuel price file unreadable: #{inspect(reason)}")
        :empty
    end
  end

  defp file_path do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get_lazy(:path, fn ->
      :charger |> :code.priv_dir() |> to_string() |> Path.join("cache/fuel-prices.json")
    end)
  end

  defp source do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:source, Charger.Prices.Ministry)
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    end
  end

  defp empty do
    %{status: :loading, stations: [], fecha: nil, fetched_at: nil, error: nil}
  end
end
