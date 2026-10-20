defmodule ChargerReve do
  @moduledoc """
  Slow download of the Reve charging catalog.

  Three lists are collected one after the other: the operators (CPOs), the
  locations of each operator, then the tariffs of the connectors. Reve pages
  by offset with no stable order, so one long walk over all locations skips
  and repeats stations while the list changes. A list per operator is short
  and is read before it moves much.

  On start the process loads `priv/cache/reve-locations.json` into ETS and
  asks for the next page immediately. It takes five successful pages and then
  waits an hour. A rate-limit response waits an hour immediately.

  Every station is its own ETS row keyed by `{:location, id}`. A station whose
  id is already in the table is not written again. A tariff is stored on the
  connector it belongs to, inside its location. Tariffs whose connector is not
  in the catalog stay in `unmatched_tariffs`, keyed by connector id, and are
  attached when that station arrives.

  Once a full location list exists, the charging catalog shows these stations
  instead of the RIPREE export.
  """

  use GenServer
  require Logger

  @table :charger_reve
  @api "https://www.mapareve.es/api/external/v1"
  @page_size 100
  @burst_size 5
  @pause_ms :timer.minutes(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    case lookup(:status) do
      nil -> empty_snapshot()
      status -> Map.put(status, :locations, all_locations())
    end
  end

  @doc """
  Stations in the shape `Charger.Chargers` reads, or nil while no full
  location list has been collected.
  """
  def catalog, do: lookup(:catalog)

  def classify(status, body) when is_integer(status) do
    cond do
      status in 200..299 and is_list(body) -> {:ok, body}
      rate_limited?(status, body) -> {:error, :rate_limited}
      true -> {:error, {:http, status}}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    state = load_file()
    publish(state)
    state = publish_catalog(state)
    state = if phase(state) == :done, do: state, else: arm(state, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:fetch, state) do
    state = cancel_timer(state)

    case phase(state) do
      :done -> {:noreply, publish(%{state | status: :complete})}
      kind -> {:noreply, fetch(state, kind)}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    cancel_timer(state)
    File.rm(file_path())
    :ets.match_delete(@table, {{:location, :_}, :_})
    blank = empty_state()
    publish(blank)
    {:reply, :ok, publish_catalog(blank)}
  end

  defp phase(%{cpos_complete: false}), do: :cpos
  defp phase(%{operators_complete: false, operators: [party_id | _]}), do: {:locations, party_id}
  defp phase(%{tariffs_complete: false}), do: :tariffs
  defp phase(_state), do: :done

  defp fetch(state, kind) do
    state = %{state | status: :collecting}
    page = page(state, kind)

    case fetch_page(kind, page) do
      {:ok, items} when is_list(items) ->
        state = store_page(%{state | successes: state.successes + 1}, kind, items)

        cond do
          phase(state) == :done ->
            publish(%{state | status: :complete})

          state.successes >= @burst_size ->
            Logger.info(
              "reve collected #{@burst_size} pages, next attempt in #{div(pause_ms(), 60_000)} minutes"
            )

            state
            |> Map.put(:successes, 0)
            |> Map.put(:status, :waiting)
            |> publish()
            |> arm(pause_ms())

          true ->
            arm(state, 0)
        end

      {:error, :rate_limited} ->
        Logger.info(
          "reve rate limit reached at #{label(kind)} page #{page}, next attempt in #{div(pause_ms(), 60_000)} minutes"
        )

        state
        |> Map.put(:successes, 0)
        |> Map.put(:error, nil)
        |> Map.put(:status, :waiting)
        |> publish()
        |> arm(pause_ms())

      {:error, reason} ->
        Logger.error("reve #{label(kind)} page #{page} failed: #{inspect(reason)}")

        state
        |> Map.put(:error, inspect(reason))
        |> Map.put(:status, :waiting)
        |> publish()
        |> arm(retry_ms())
    end
  end

  defp page(state, :cpos), do: state.cpo_page
  defp page(state, {:locations, _party_id}), do: state.operator_page
  defp page(state, :tariffs), do: state.tariff_page

  defp label({:locations, party_id}), do: "locations #{party_id}"
  defp label(kind), do: Atom.to_string(kind)

  defp fetch_page(kind, page) do
    case source() do
      nil -> request_page(kind, page)
      mod -> mod.fetch_page(kind, page)
    end
  end

  defp request_page(kind, page) when is_integer(page) and page >= 1 do
    case api_key() do
      key when is_binary(key) and key != "" ->
        case Req.get(@api <> path(kind),
               headers: [{"x-api-key", key}, {"accept", "application/json"}],
               params: params(kind, page),
               receive_timeout: 120_000,
               retry: &retry?/2
             ) do
          {:ok, %{status: status, body: body}} ->
            result = classify(status, body)

            case result do
              {:ok, _items} ->
                :ok

              {:error, reason} ->
                Logger.error(
                  "reve api #{label(kind)} page #{page} failed: #{inspect(reason)}, status=#{status}, body=#{truncate(body)}"
                )
            end

            result

          {:error, reason} ->
            Logger.error("reve api #{label(kind)} page #{page} failed: #{inspect(reason)}")
            {:error, reason}
        end

      _ ->
        Logger.error("reve api #{label(kind)} page #{page} failed: missing api key")
        {:error, :missing_api_key}
    end
  end

  defp path(:cpos), do: "/cpos"
  defp path({:locations, _party_id}), do: "/locations"
  defp path(:tariffs), do: "/connectors/tariffs"

  defp params({:locations, party_id}, page),
    do: [party_id: party_id, page: page, limit: @page_size]

  defp params(_kind, page), do: [page: page, limit: @page_size]

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp truncate(body), do: inspect(body, limit: 20, printable_limit: 300)

  defp api_key do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:api_key) ||
      System.get_env("REVE_API_KEY")
  end

  def retry?(%{method: method}, %Req.Response{status: 429}) when method in [:get, :head],
    do: false

  def retry?(%{method: method}, %Req.Response{status: status})
      when method in [:get, :head] and status in [408, 500, 502, 503, 504],
      do: true

  def retry?(%{method: method}, %Req.TransportError{reason: reason})
      when method in [:get, :head] and reason in [:timeout, :econnrefused, :closed],
      do: true

  def retry?(%{method: method}, %Req.HTTPError{protocol: :http2, reason: reason})
      when method in [:get, :head] and reason in [:unprocessed, :pool_not_available],
      do: true

  def retry?(_request, _response_or_exception), do: false

  defp rate_limited?(429, _body), do: true

  defp rate_limited?(_status, body) do
    text =
      case body do
        binary when is_binary(binary) -> binary
        other -> inspect(other)
      end
      |> String.downcase()

    Enum.any?(
      ["límite", "limite", "rate limit", "too many", "too_many", "quota", "cuota"],
      &String.contains?(text, &1)
    )
  end

  defp store_page(state, :cpos, page_cpos) do
    party_ids = for %{"party_id" => id} <- page_cpos, is_binary(id) and id != "", do: id
    complete = length(page_cpos) < @page_size

    Logger.info(
      "reve cpos page #{state.cpo_page}: received #{length(page_cpos)}, " <>
        "party ids #{length(party_ids)}, complete=#{complete}"
    )

    if party_ids == [] and page_cpos != [] do
      Logger.error("reve cpos have no party_id, keys: #{inspect(Map.keys(hd(page_cpos)))}")
    end

    state = %{
      state
      | operators: Enum.uniq(state.operators ++ party_ids),
        cpo_page: state.cpo_page + 1,
        cpos_complete: complete,
        updated_at: now(),
        error: nil
    }

    state = if complete, do: queue_operators(state), else: state
    publish(state)
    write_file(state)
    state
  end

  defp store_page(state, {:locations, party_id}, page_locations) do
    added = insert_new_locations(page_locations)
    {index, unmatched, attached} = attach_waiting_tariffs(state, added)
    done = length(page_locations) < @page_size
    others = Enum.count(page_locations, &(is_map(&1) and &1["party_id"] != party_id))

    Logger.info(
      "reve locations #{party_id} page #{state.operator_page}: received #{length(page_locations)}, " <>
        "new #{length(added)}, already stored #{length(page_locations) - length(added)}, " <>
        "other operators #{others}, tariffs attached #{attached}, stored total #{location_count()}"
    )

    state = %{
      state
      | connector_index: index,
        unmatched_tariffs: unmatched,
        updated_at: now(),
        error: nil
    }

    state =
      if done do
        state |> next_operator() |> refresh_catalog()
      else
        %{state | operator_page: state.operator_page + 1}
      end

    publish(state)
    write_file(state)
    state
  end

  defp store_page(state, :tariffs, page_tariffs) do
    index = state.connector_index || connector_index(all_locations())

    {unmatched, matched} =
      attach_tariffs(index, Enum.filter(page_tariffs, &is_map/1), state.unmatched_tariffs)

    complete = length(page_tariffs) < @page_size

    state = %{
      state
      | connector_index: index,
        unmatched_tariffs: unmatched,
        tariff_page: state.tariff_page + 1,
        tariffs_complete: complete,
        updated_at: now(),
        error: nil
    }

    publish(state)
    write_file(state)

    Logger.info(
      "reve tariffs page #{state.tariff_page - 1}: received #{length(page_tariffs)}, " <>
        "on connectors #{matched}, unmatched total #{map_size(unmatched)}, complete=#{complete}"
    )

    state
  end

  defp queue_operators(state) do
    known =
      all_locations()
      |> Enum.map(& &1["party_id"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    listed_only = state.operators -- known
    operators = known ++ listed_only

    Logger.info(
      "reve operators to collect: #{length(known)} with stored stations, " <>
        "#{length(listed_only)} only in the CPO list"
    )

    %{state | operators: operators, operator_page: 1, operators_complete: operators == []}
  end

  defp next_operator(%{operators: [party_id | rest]} = state) do
    Logger.info("reve operator #{party_id} done, #{length(rest)} operators left")
    state = %{state | operators: rest, operator_page: 1}
    if rest == [], do: %{state | operators_complete: true, complete: true}, else: state
  end

  defp insert_new_locations(page_locations) do
    for %{"id" => id} = location <- page_locations,
        is_binary(id) and id != "",
        :ets.insert_new(@table, {{:location, id}, location}),
        do: location
  end

  defp attach_waiting_tariffs(state, added) do
    entries = connector_index(added)
    index = state.connector_index && Map.merge(state.connector_index, entries)
    waiting = state.unmatched_tariffs |> Map.take(Map.keys(entries)) |> Map.values()
    {unmatched, attached} = attach_tariffs(entries, waiting, state.unmatched_tariffs)
    {index, unmatched, attached}
  end

  defp connector_index(locations) do
    for %{"id" => location_id} = location <- locations,
        %{} = evse <- List.wrap(location["evses"]),
        %{"id" => connector_id} <- List.wrap(evse["connectors"]),
        is_binary(connector_id),
        into: %{},
        do: {connector_id, location_id}
  end

  defp attach_tariffs(index, tariffs, unmatched) do
    {by_location, unmatched, matched} =
      Enum.reduce(tariffs, {%{}, unmatched, 0}, fn tariff, {by_location, unmatched, matched} ->
        connector_id = tariff["connector_id"]

        case Map.fetch(index, connector_id) do
          {:ok, location_id} ->
            by_location =
              Map.update(
                by_location,
                location_id,
                %{connector_id => tariff},
                &Map.put(&1, connector_id, tariff)
              )

            {by_location, Map.delete(unmatched, connector_id), matched + 1}

          :error when is_binary(connector_id) ->
            {by_location, Map.put(unmatched, connector_id, tariff), matched}

          :error ->
            {by_location, unmatched, matched}
        end
      end)

    Enum.each(by_location, fn {location_id, tariffs} ->
      update_location(location_id, &put_tariffs(&1, tariffs))
    end)

    {unmatched, matched}
  end

  defp update_location(id, fun) do
    case :ets.lookup(@table, {:location, id}) do
      [{key, location}] -> :ets.insert(@table, {key, fun.(location)})
      [] -> :ok
    end
  end

  defp put_tariffs(location, tariffs) do
    Map.update(location, "evses", [], fn
      evses when is_list(evses) -> Enum.map(evses, &put_evse_tariffs(&1, tariffs))
      other -> other
    end)
  end

  defp put_evse_tariffs(%{"connectors" => connectors} = evse, tariffs) when is_list(connectors) do
    %{evse | "connectors" => Enum.map(connectors, &put_tariff(&1, tariffs))}
  end

  defp put_evse_tariffs(evse, _tariffs), do: evse

  defp put_tariff(%{"id" => id} = connector, tariffs) do
    case Map.fetch(tariffs, id) do
      {:ok, tariff} -> Map.merge(connector, Map.take(tariff, ["tariffs", "last_tariff_updated"]))
      :error -> connector
    end
  end

  defp put_tariff(connector, _tariffs), do: connector

  defp all_locations do
    :ets.select(@table, [{{{:location, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp location_count do
    :ets.select_count(@table, [{{{:location, :_}, :_}, [], [true]}])
  end

  defp write_file(state) do
    locations =
      :ets.select(@table, [{{{:location, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Map.new()

    body = %{
      "complete" => state.complete,
      "cpo_page" => state.cpo_page,
      "cpos_complete" => state.cpos_complete,
      "operators" => state.operators,
      "operator_page" => state.operator_page,
      "operators_complete" => state.operators_complete,
      "tariff_page" => state.tariff_page,
      "tariffs_complete" => state.tariffs_complete,
      "locations" => locations,
      "unmatched_tariffs" => state.unmatched_tariffs
    }

    case Jason.encode(body) do
      {:ok, json} ->
        case Charger.CacheFile.write(file_path(), json, state.updated_at) do
          :ok -> :ok
          {:error, reason} -> Logger.error("reve file write failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("reve file encode failed: #{inspect(reason)}")
    end
  end

  defp load_file do
    case Charger.CacheFile.read(file_path()) do
      {:ok, json, updated_at} ->
        case Jason.decode(json) do
          {:ok, %{"complete" => complete, "locations" => locations} = body}
          when is_boolean(complete) and (is_map(locations) or is_list(locations)) ->
            insert_locations(locations)

            %{
              empty_state()
              | complete: complete,
                cpo_page: positive(body["cpo_page"]),
                cpos_complete: body["cpos_complete"] == true,
                operators: strings(body["operators"]),
                operator_page: positive(body["operator_page"]),
                operators_complete: body["operators_complete"] == true,
                tariff_page: positive(body["tariff_page"]),
                tariffs_complete: body["tariffs_complete"] == true,
                unmatched_tariffs: map(body["unmatched_tariffs"]),
                updated_at: updated_at
            }

          _ ->
            Logger.error("reve file has an unexpected shape")
            empty_state()
        end

      {:error, :enoent} ->
        empty_state()

      {:error, reason} ->
        Logger.error("reve file unreadable: #{inspect(reason)}")
        empty_state()
    end
  end

  defp insert_locations(locations) when is_map(locations),
    do: insert_locations(Map.values(locations))

  defp insert_locations(locations) when is_list(locations) do
    rows =
      for %{"id" => id} = location <- locations, is_binary(id), do: {{:location, id}, location}

    :ets.insert(@table, rows)
  end

  defp positive(value) when is_integer(value) and value >= 1, do: value
  defp positive(_value), do: 1

  defp strings(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp strings(_value), do: []

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp publish(state) do
    :ets.insert(@table, {:status, status_from(state)})
    state
  end

  defp refresh_catalog(%{complete: true} = state) do
    if location_count() != state.catalog_count, do: publish_catalog(state), else: state
  end

  defp refresh_catalog(state), do: state

  defp publish_catalog(%{complete: true} = state) do
    sites = all_locations() |> Charger.Chargers.ReveSites.from_locations()

    catalog = %{
      status: :ready,
      sites: sites,
      overlap: nil,
      fetched_at: state.updated_at,
      error: nil
    }

    :ets.insert(@table, {:catalog, catalog})
    Phoenix.PubSub.broadcast(Charger.PubSub, "chargers", :updated)

    Logger.info(
      "reve catalog ready: #{length(sites)} charging stations replace RIPREE on the page"
    )

    %{state | catalog_count: length(sites)}
  end

  defp publish_catalog(state) do
    :ets.insert(@table, {:catalog, nil})
    state
  end

  defp status_from(state) do
    %{
      status: state.status,
      count: location_count(),
      complete: state.complete,
      cpo_page: state.cpo_page,
      cpos_complete: state.cpos_complete,
      operator: List.first(state.operators),
      operators_left: length(state.operators),
      operator_page: state.operator_page,
      operators_complete: state.operators_complete,
      tariff_page: state.tariff_page,
      tariffs_complete: state.tariffs_complete,
      unmatched_tariffs: map_size(state.unmatched_tariffs),
      updated_at: state.updated_at,
      error: state.error
    }
  end

  defp lookup(key) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end
  end

  defp arm(state, 0) do
    send(self(), :fetch)
    cancel_timer(state)
  end

  defp arm(state, delay) when is_integer(delay) and delay > 0 do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :fetch, delay)}
  end

  defp cancel_timer(%{timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp source do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:source)
  end

  defp pause_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:pause_ms, @pause_ms)
  end

  defp retry_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:retry_ms, :timer.minutes(1))
  end

  defp file_path do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get_lazy(:path, fn ->
      :charger |> :code.priv_dir() |> to_string() |> Path.join("cache/reve-locations.json")
    end)
  end

  defp empty_state do
    %{
      status: :collecting,
      complete: false,
      cpo_page: 1,
      cpos_complete: false,
      operators: [],
      operator_page: 1,
      operators_complete: false,
      tariff_page: 1,
      tariffs_complete: false,
      unmatched_tariffs: %{},
      connector_index: nil,
      catalog_count: 0,
      updated_at: nil,
      error: nil,
      successes: 0,
      timer: nil
    }
  end

  defp empty_snapshot do
    %{
      status: :loading,
      count: 0,
      complete: false,
      cpo_page: 1,
      cpos_complete: false,
      operator: nil,
      operators_left: 0,
      operator_page: 1,
      operators_complete: false,
      tariff_page: 1,
      tariffs_complete: false,
      unmatched_tariffs: 0,
      updated_at: nil,
      error: nil,
      locations: []
    }
  end
end
