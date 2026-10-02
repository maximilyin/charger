defmodule Charger.Chargers.Cache do
  @moduledoc """
  ETS snapshot of the public charging catalog.

  This process is the only one that downloads the RIPREE file. It refreshes
  on startup and then once a day. Pages only read the table.
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

  def interval_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:interval_ms, :timer.hours(24))
  end

  defp refresh do
    case source().fetch() do
      {:ok, payload} ->
        parsed = Charger.Chargers.Parser.parse(payload)
        fuel = Charger.Prices.Cache.snapshot().stations

        snapshot = %{
          status: :ready,
          sites: parsed.sites,
          overlap: Charger.Chargers.Overlap.report(fuel, parsed.sites),
          fetched_at: DateTime.utc_now(),
          error: nil
        }

        :ets.insert(@table, {:snapshot, snapshot})
        log_overlap(snapshot)
        Phoenix.PubSub.broadcast(Charger.PubSub, "chargers", :updated)

      {:error, reason} ->
        Logger.error("charger catalog refresh failed: #{inspect(reason)}")
        current = snapshot()

        updated =
          if current.sites == [] do
            %{current | status: :error, error: inspect(reason)}
          else
            %{current | error: inspect(reason)}
          end

        :ets.insert(@table, {:snapshot, updated})
    end
  end

  defp recompute_overlap do
    current = snapshot()

    if current.sites != [] do
      fuel = Charger.Prices.Cache.snapshot().stations
      overlap = Charger.Chargers.Overlap.report(fuel, current.sites)

      if overlap != current.overlap do
        updated = %{current | overlap: overlap}
        :ets.insert(@table, {:snapshot, updated})
        log_overlap(updated)
      end
    end
  end

  defp log_overlap(%{sites: sites, overlap: overlap}) do
    Logger.info(
      "charger catalog updated: #{length(sites)} sites; " <>
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
