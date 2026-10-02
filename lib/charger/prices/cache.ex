defmodule Charger.Prices.Cache do
  @moduledoc """
  ETS snapshot of fuel prices.

  This process is the only one that calls the ministry. It refreshes on
  startup and then every hour. Web requests only read the table.
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

  def interval_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:interval_ms, :timer.hours(1))
  end

  defp refresh do
    case source().fetch() do
      {:ok, payload} ->
        snapshot =
          payload
          |> Charger.Prices.Parser.parse()
          |> Map.put(:status, :ready)
          |> Map.put(:error, nil)

        :ets.insert(@table, {:snapshot, snapshot})
        Logger.info("fuel price cache updated: #{length(snapshot.stations)} stations")
        Phoenix.PubSub.broadcast(Charger.PubSub, @topic, :updated)

      {:error, reason} ->
        Logger.error("fuel price refresh failed: #{inspect(reason)}")
        current = snapshot()

        updated =
          if current.stations == [] do
            %{current | status: :error, error: inspect(reason)}
          else
            %{current | error: inspect(reason)}
          end

        :ets.insert(@table, {:snapshot, updated})
        Phoenix.PubSub.broadcast(Charger.PubSub, @topic, :updated)
    end
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
