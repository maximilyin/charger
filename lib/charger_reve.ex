defmodule ChargerReve do
  @moduledoc """
  Slow download of the Reve location catalog.

  On start the process loads `priv/cache/reve-locations.json` into ETS, then
  asks for the next page immediately. It keeps asking until Reve answers that
  the request limit is spent, then waits one hour and continues. The catalog
  page does not read this table.

  `locations` in the file is an object keyed by station id. A later response
  for the same id is merged into that object, so prices and other fields stay.
  """

  use GenServer
  require Logger

  @table :charger_reve
  @url "https://www.mapareve.es/api/external/v1/locations"
  @page_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    if :ets.whereis(@table) == :undefined do
      empty_snapshot()
    else
      case :ets.lookup(@table, :snapshot) do
        [{:snapshot, snapshot}] -> snapshot
        [] -> empty_snapshot()
      end
    end
  end

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
    state = if state.complete, do: state, else: arm(state, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:fetch, %{complete: true} = state) do
    {:noreply, state}
  end

  def handle_info(:fetch, state) do
    state = %{cancel_timer(state) | status: :collecting}

    state =
      case fetch_page(state.next_page) do
        {:ok, locations} when is_list(locations) ->
          state = store_page(state, locations)
          if state.complete, do: state, else: arm(state, 0)

        {:error, :rate_limited} ->
          Logger.info(
            "reve rate limit reached at page #{state.next_page}, next attempt in #{div(pause_ms(), 60_000)} minutes"
          )

          state
          |> Map.put(:error, nil)
          |> Map.put(:status, :waiting)
          |> publish()
          |> arm(pause_ms())

        {:error, reason} ->
          Logger.error("reve page #{state.next_page} failed: #{inspect(reason)}")

          state
          |> Map.put(:error, inspect(reason))
          |> Map.put(:status, :waiting)
          |> publish()
          |> arm(retry_ms())
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    cancel_timer(state)
    File.rm(file_path())
    blank = empty_state()
    publish(blank)
    {:reply, :ok, blank}
  end

  defp fetch_page(page) do
    case source() do
      nil -> request_page(page)
      mod -> mod.fetch_page(page)
    end
  end

  defp request_page(page) when is_integer(page) and page >= 1 do
    case api_key() do
      key when is_binary(key) and key != "" ->
        case Req.get(@url,
               headers: [{"x-api-key", key}, {"accept", "application/json"}],
               params: [page: page, limit: @page_size],
               receive_timeout: 120_000,
               retry: &retry?/2
             ) do
          {:ok, %{status: status, body: body}} ->
            result = classify(status, body)

            case result do
              {:ok, _locations} ->
                :ok

              {:error, reason} ->
                Logger.error(
                  "reve api page #{page} failed: #{inspect(reason)}, status=#{status}, body=#{truncate(body)}"
                )
            end

            result

          {:error, reason} ->
            Logger.error("reve api page #{page} failed: #{inspect(reason)}")
            {:error, reason}
        end

      _ ->
        Logger.error("reve api page #{page} failed: missing api key")
        {:error, :missing_api_key}
    end
  end

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

  defp store_page(state, page_locations) do
    locations = Enum.reduce(page_locations, state.locations, &merge_location/2)

    complete = length(page_locations) < @page_size
    updated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    state = %{
      state
      | locations: locations,
        next_page: state.next_page + 1,
        complete: complete,
        status: if(complete, do: :complete, else: :collecting),
        updated_at: updated_at,
        error: nil
    }

    publish(state)
    write_file(state)

    Logger.info(
      "reve locations page #{state.next_page - 1}: received #{length(page_locations)}, " <>
        "stored #{map_size(locations)}, complete=#{complete}"
    )

    state
  end

  defp write_file(state) do
    body = %{
      "next_page" => state.next_page,
      "complete" => state.complete,
      "locations" => state.locations
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
          {:ok, %{"next_page" => page, "complete" => complete, "locations" => locations}}
          when is_integer(page) and page >= 1 and is_boolean(complete) and
                 (is_map(locations) or is_list(locations)) ->
            kept = locations_by_id(locations)

            %{
              empty_state()
              | locations: kept,
                next_page: page,
                complete: complete,
                status: if(complete, do: :complete, else: :collecting),
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

  defp merge_location(%{"id" => id} = location, locations) when is_binary(id) and id != "" do
    Map.update(locations, id, location, &Map.merge(&1, location))
  end

  defp merge_location(_location, locations), do: locations

  defp locations_by_id(locations) when is_list(locations) do
    Enum.reduce(locations, %{}, &merge_location/2)
  end

  defp locations_by_id(locations) when is_map(locations) do
    locations |> Map.values() |> locations_by_id()
  end

  defp publish(state) do
    :ets.insert(@table, {:snapshot, snapshot_from(state)})
    state
  end

  defp snapshot_from(state) do
    %{
      status: state.status,
      next_page: state.next_page,
      count: map_size(state.locations),
      complete: state.complete,
      updated_at: state.updated_at,
      error: state.error,
      locations: Map.values(state.locations)
    }
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

  defp source do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:source)
  end

  defp pause_ms do
    Application.get_env(:charger, __MODULE__, [])
    |> Keyword.get(:pause_ms, :timer.hours(1))
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
      next_page: 1,
      locations: %{},
      complete: false,
      updated_at: nil,
      error: nil,
      timer: nil
    }
  end

  defp empty_snapshot do
    %{
      status: :loading,
      next_page: 1,
      count: 0,
      complete: false,
      updated_at: nil,
      error: nil,
      locations: []
    }
  end
end
