defmodule Charger.Sessions do
  @moduledoc """
  Client sessions kept in ETS.

  The browser cookie only stores the session id. Filters live in the table.
  A visit refreshes the 24 hour lifetime; the owner process drops rows that
  have not been used since then.
  """

  use GenServer

  @table :charger_sessions
  @ttl_seconds 24 * 60 * 60
  @sweep_interval_ms :timer.minutes(15)
  @fuels ~w(gasoline_95 gasoline_98 diesel_a diesel_premium charging)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def new_id do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  def default_filters do
    %{province: "", municipality: "", fuel: "gasoline_95", q: ""}
  end

  def ensure(id) when is_binary(id) do
    case fetch(id) do
      {:ok, filters} ->
        filters

      :miss ->
        filters = default_filters()
        put(id, filters)
        filters
    end
  end

  def fetch(id) when is_binary(id) do
    now = now()

    case :ets.lookup(@table, id) do
      [{^id, filters, expires_at}] when expires_at > now ->
        :ets.insert(@table, {id, filters, now + ttl_seconds()})
        {:ok, filters}

      [{^id, _filters, _expires_at}] ->
        :ets.delete(@table, id)
        :miss

      [] ->
        :miss
    end
  end

  def put(id, filters) when is_binary(id) and is_map(filters) do
    :ets.insert(@table, {id, normalize(filters), now() + ttl_seconds()})
    :ok
  end

  def sweep do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  def ttl_seconds, do: @ttl_seconds

  @impl true
  def init(_opts) do
    create_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp normalize(filters) do
    %{
      province: text(filters[:province] || filters["province"]),
      municipality: text(filters[:municipality] || filters["municipality"]),
      fuel: normalize_fuel(filters[:fuel] || filters["fuel"]),
      q: text(filters[:q] || filters["q"])
    }
  end

  defp normalize_fuel(fuel) when fuel in @fuels, do: fuel
  defp normalize_fuel(_fuel), do: "gasoline_95"

  defp text(nil), do: ""
  defp text(value), do: value |> to_string() |> String.trim()

  defp now, do: System.system_time(:second)
end
