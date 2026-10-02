defmodule ChargerWeb.CatalogLive do
  use ChargerWeb, :live_view

  @topic "prices"

  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Charger.PubSub, @topic)
      Phoenix.PubSub.subscribe(Charger.PubSub, "chargers")
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Fuel in Spain"))
     |> assign(:client_id, session["client_id"])
     |> assign(:origin, nil)
     |> assign(:geo_status, :idle)
     |> assign(:shown, page_size())
     |> assign(:view, :table)
     |> assign(:map_count, 0)
     |> assign(Charger.Sessions.default_filters())}
  end

  def handle_params(params, _uri, socket) do
    filters = params |> filters_from_url() |> align_filters()

    if is_binary(socket.assigns.client_id) do
      Charger.Sessions.put(socket.assigns.client_id, filters)
    end

    shown = if same_filters?(socket, filters), do: socket.assigns.shown, else: page_size()

    {:noreply, socket |> assign(filters) |> assign(:shown, shown) |> load()}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <section id="catalog">
        <header class="catalog-top">
          <div>
            <h1>{gettext("Fuel in Spain")}</h1>
            <p :if={updated_clock(@result)} id="catalog-updated" class="catalog-updated">
              {gettext("Updated at %{time}", time: updated_clock(@result))}
            </p>
          </div>
          <div class="catalog-tools">
            <nav class="catalog-locales" aria-label={gettext("Language")}>
              <.link
                :for={%{code: code, label: label} <- locales()}
                href={locale_href(code, @province, @municipality, @fuel, @q)}
                class={[@locale == code && "is-active"]}
              >
                {label}
              </.link>
            </nav>
            <Layouts.theme_toggle />
          </div>
        </header>

        <div id="catalog-layout" class="catalog-body">
          <aside>
            <form id="filters" phx-change="filter" class="catalog-filters">
              <label>
                <span>{gettext("Province")}</span>
                <select name="filters[province]">
                  <option value="">{gettext("All provinces")}</option>
                  <option
                    :for={province <- @result.provinces}
                    value={province}
                    selected={province == @province}
                  >
                    {province}
                  </option>
                </select>
              </label>

              <label>
                <span>{gettext("Municipality")}</span>
                <select name="filters[municipality]">
                  <option value="">{gettext("All in the province")}</option>
                  <option
                    :for={municipality <- @result.municipalities}
                    value={municipality}
                    selected={municipality == @municipality}
                  >
                    {municipality}
                  </option>
                </select>
              </label>

              <div>
                <span id="fuel-label">{gettext("Fuel")}</span>
                <div class="fuel-chips" role="group" aria-labelledby="fuel-label">
                  <button
                    :for={fuel <- filter_fuels()}
                    type="button"
                    id={"fuel-#{fuel}"}
                    phx-click="fuel"
                    phx-value-fuel={fuel}
                    class={["fuel-chip", @fuel == Atom.to_string(fuel) && "is-active"]}
                    title={fuel_label(fuel)}
                    aria-pressed={to_string(@fuel == Atom.to_string(fuel))}
                  >
                    {fuel_chip(fuel)}
                  </button>
                </div>
              </div>

              <label>
                <span>{gettext("Brand or address")}</span>
                <input
                  type="search"
                  name="filters[q]"
                  value={@q}
                  placeholder="Repsol, Calle..."
                  phx-debounce="300"
                />
              </label>

              <div class="catalog-actions">
                <button
                  id="near-me"
                  type="button"
                  phx-hook="NearMe"
                  data-active={@origin && "true"}
                  class={["text-button", @origin && "is-active"]}
                  aria-pressed={to_string(not is_nil(@origin))}
                >
                  {gettext("Near me")}
                </button>
                <p :if={@geo_status == :error} id="geo-error" class="geo-error">
                  {gettext("Location is unavailable.")}
                </p>
                <button id="reset-filters" type="button" phx-click="reset" class="text-button">
                  {gettext("Reset filters")}
                </button>
              </div>
            </form>
          </aside>

          <div>
            <div class="catalog-stats">
              <.stat
                id="stat-cheapest"
                label={edge_label(:low, @result.fuel)}
                value={edge_value(@result.cheapest, @result.fuel, @locale)}
              />
              <.stat
                id="stat-median"
                label={gettext("Median")}
                value={edge_value(@result.median, @result.fuel, @locale)}
              />
              <.stat
                id="stat-dearest"
                label={edge_label(:high, @result.fuel)}
                value={edge_value(@result.dearest, @result.fuel, @locale)}
              />
              <.stat id="station-count" label={gettext("Stations")} value={@result.total} />
            </div>

            <div :if={@result.status == :ready} class="catalog-toolbar">
              <p :if={@result.total > 0} id="catalog-caption" class="catalog-caption">
                {caption(@result, @origin, @view, @map_count)}
              </p>
              <div id="catalog-views" class="catalog-views" role="group" aria-label={gettext("View")}>
                <button
                  id="view-table"
                  type="button"
                  phx-click="view"
                  phx-value-view="table"
                  class={["text-button", "view-button", @view == :table && "is-active"]}
                  title={gettext("Table")}
                  aria-label={gettext("Table")}
                  aria-pressed={to_string(@view == :table)}
                >
                  <.icon name="hero-list-bullet" />
                </button>
                <button
                  id="view-map"
                  type="button"
                  phx-click="view"
                  phx-value-view="map"
                  class={["text-button", "view-button", @view == :map && "is-active"]}
                  title={gettext("Map")}
                  aria-label={gettext("Map")}
                  aria-pressed={to_string(@view == :map)}
                >
                  <.icon name="hero-globe-alt" />
                </button>
              </div>
            </div>

            <div :if={@result.status == :loading} id="catalog-state" class="catalog-state">
              {loading_text(@result.fuel)}
            </div>

            <div :if={@result.status == :error} id="catalog-state" class="catalog-state">
              {empty_cache_text(@result.fuel)}
            </div>

            <div
              :if={@result.status == :ready and @result.total == 0}
              id="catalog-state"
              class="catalog-state"
            >
              {gettext("No stations match these filters.")}
            </div>

            <div
              :if={@view == :map and @result.total > 0}
              id="station-map"
              phx-hook="StationMap"
              phx-update="ignore"
              class="station-map"
            >
            </div>

            <div :if={@view == :table and @result.stations != []} class="overflow-x-auto">
              <table class="catalog-table">
                <thead>
                  <tr>
                    <th>{column_label(@result.fuel)}</th>
                    <th>{gettext("Sign")}</th>
                    <th>{gettext("Address")}</th>
                    <th :if={@origin}>{gettext("Distance")}</th>
                    <th>{gettext("Schedule")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody id="stations">
                  <tr
                    :for={station <- @result.stations}
                    id={"station-#{station.id}"}
                    class={station.open == :closed && "is-closed"}
                  >
                    <.price_cell
                      station={station}
                      median={@result.median}
                      fuel={@result.fuel}
                      locale={@locale}
                    />
                    <td class="brand" title={brand_title(station)}>{station.brand}</td>
                    <td>{place(station)}</td>
                    <td :if={@origin} class="distance">
                      {distance_text(station.distance_m, @locale)}
                    </td>
                    <td class={["schedule", schedule_text(station) == "24H" && "is-24h"]}>
                      {schedule_text(station)}
                    </td>
                    <td class="map">
                      <.link
                        id={"map-#{station.id}"}
                        href={Charger.Prices.maps_url(station)}
                        target="_blank"
                        rel="noopener noreferrer"
                        aria-label={gettext("Show on Google Maps")}
                        title={gettext("Show on Google Maps")}
                      >
                        <.icon name="hero-map-pin" class="size-5" />
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <button
              :if={
                @view == :table and @result.stations != [] and
                  length(@result.stations) < @result.total
              }
              id="show-more"
              type="button"
              phx-click="show_more"
              class="show-more"
            >
              {gettext("Show more")}
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="catalog-stat">
      <p class="stat-label">{@label}</p>
      <p id={@id} class="stat-value">{@value}</p>
    </div>
    """
  end

  attr :station, :map, required: true
  attr :median, :any, default: nil
  attr :fuel, :atom, required: true
  attr :locale, :string, required: true

  defp price_cell(assigns) do
    ~H"""
    <td class="price">
      <%= if @fuel == :charging do %>
        <div class="price-main">{Charger.Chargers.format_power(@station.price, @locale)}</div>
        <p :if={@station.plugs != []} class="fuel-line">
          <span :for={plug <- @station.plugs} class="fuel-bit" title={plug_title(plug)}>
            <span class="fuel-name">{plug_name(plug)}</span>
            <span :if={is_integer(plug.watts)} class="fuel-price">
              {Charger.Chargers.format_power(plug.watts, @locale)}
            </span>
          </span>
        </p>
      <% else %>
        <div class="price-main">{Charger.Prices.format_price(@station.price, @locale)}</div>
        <div
          :if={is_integer(@median)}
          class={delta_class(@station.price - @median)}
          title={gettext("Compared with the median")}
        >
          {Charger.Prices.format_delta(@station.price - @median, @locale)}
        </div>
        <p class="fuel-line">
          <span
            :for={bit <- fuel_bits(@station)}
            class={["fuel-bit", bit.fuel == @fuel && "is-current"]}
            title={fuel_label(bit.fuel)}
          >
            <span class="fuel-name">{fuel_short(bit.fuel)}</span>
            <span class="fuel-price">{Charger.Prices.format_price(bit.price, @locale)}</span>
          </span>
        </p>
      <% end %>
    </td>
    """
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    province = blank(params["province"])

    municipality =
      if province == socket.assigns.province, do: blank(params["municipality"]), else: ""

    filters = %{
      province: province,
      municipality: municipality,
      fuel: socket.assigns.fuel,
      q: blank(params["q"])
    }

    {:noreply, push_patch(socket, to: catalog_path(filters))}
  end

  def handle_event("fuel", %{"fuel" => fuel}, socket) do
    filters =
      socket
      |> current_filters()
      |> Map.put(:fuel, normalize_fuel(fuel))
      |> align_filters()

    {:noreply, push_patch(socket, to: catalog_path(filters))}
  end

  def handle_event("reset", _params, socket) do
    socket = socket |> assign(:origin, nil) |> assign(:geo_status, :idle)

    if catalog_path(current_filters(socket)) == ~p"/" do
      {:noreply,
       socket
       |> assign(Charger.Sessions.default_filters())
       |> assign(:shown, page_size())
       |> load()}
    else
      {:noreply, push_patch(socket, to: ~p"/")}
    end
  end

  def handle_event("view", %{"view" => "map"}, socket) do
    {:noreply, socket |> assign(:view, :map) |> load()}
  end

  def handle_event("view", %{"view" => "table"}, socket) do
    {:noreply, assign(socket, :view, :table)}
  end

  def handle_event("show_more", _params, socket) do
    {:noreply, socket |> update(:shown, &(&1 + page_size())) |> load()}
  end

  def handle_event("near_me", %{"clear" => clear}, socket) when clear in [true, "true"] do
    {:noreply, socket |> assign(:origin, nil) |> assign(:geo_status, :idle) |> load()}
  end

  def handle_event("near_me", params, socket) do
    case origin_from_event(params) do
      {:ok, origin} ->
        {:noreply,
         socket
         |> assign(:origin, origin)
         |> assign(:geo_status, :ready)
         |> assign(:shown, page_size())
         |> load()}

      :error ->
        {:noreply, assign(socket, :geo_status, :error)}
    end
  end

  def handle_info(:updated, socket) do
    {:noreply, load(socket)}
  end

  defp load(socket) do
    origin = socket.assigns.origin

    params = %{
      "province" => socket.assigns.province,
      "municipality" => socket.assigns.municipality,
      "fuel" => socket.assigns.fuel,
      "q" => socket.assigns.q,
      "near_lat" => origin && origin.lat,
      "near_lng" => origin && origin.lng,
      "take" => socket.assigns.shown,
      "points" => socket.assigns.view == :map
    }

    result =
      if socket.assigns.fuel == "charging" do
        Charger.Chargers.query(params)
      else
        Charger.Prices.query(params)
      end

    points = result.points
    result = Map.delete(result, :points)
    socket = assign(socket, :result, result)

    if socket.assigns.view == :map do
      socket
      |> assign(:map_count, length(points))
      |> push_event("map-points", map_payload(points, result, socket.assigns.locale))
    else
      socket
    end
  end

  defp filters_from_url(params) do
    %{
      province: blank(params["province"]),
      municipality: blank(params["municipality"]),
      fuel: normalize_fuel(params["fuel"]),
      q: blank(params["q"])
    }
  end

  defp current_filters(socket) do
    Map.take(socket.assigns, [:province, :municipality, :fuel, :q])
  end

  defp same_filters?(socket, filters), do: current_filters(socket) == filters

  defp catalog_path(filters) do
    case filter_query(filters) do
      [] -> ~p"/"
      query -> ~p"/?#{query}"
    end
  end

  defp locale_href(code, province, municipality, fuel, q) do
    filters = %{province: province, municipality: municipality, fuel: fuel, q: q}

    case filter_query(filters) do
      [] -> ~p"/locale/#{code}"
      query -> ~p"/locale/#{code}?#{query}"
    end
  end

  defp filter_query(filters) do
    fuel = if filters.fuel == "gasoline_95", do: "", else: filters.fuel

    [
      province: blank(filters.province),
      municipality: blank(filters.municipality),
      fuel: fuel,
      q: blank(filters.q)
    ]
    |> Enum.reject(fn {_key, value} -> value == "" end)
  end

  defp origin_from_event(params) do
    with {lat, _rest} <- event_number(params["lat"]),
         {lng, _rest} <- event_number(params["lng"]),
         true <- lat >= -90 and lat <= 90 and lng >= -180 and lng <= 180 do
      {:ok, %{lat: lat, lng: lng}}
    else
      _ -> :error
    end
  end

  defp event_number(value) when is_float(value), do: {value, ""}
  defp event_number(value) when is_integer(value), do: {value / 1, ""}
  defp event_number(value) when is_binary(value), do: Float.parse(String.trim(value))
  defp event_number(_value), do: :error

  defp page_size do
    Application.get_env(:charger, :catalog_page_size, 50)
  end

  defp map_payload(points, result, locale) do
    %{
      link: gettext("Show on Google Maps"),
      points:
        Enum.map(points, fn point ->
          %{
            id: point.id,
            lat: point.lat,
            lng: point.lng,
            price: edge_value(point.price, result.fuel, locale),
            tier: price_tier(point.price, result.median),
            brand: point.brand,
            place: point.place,
            href: Charger.Prices.maps_url(%{latitude: point.lat, longitude: point.lng})
          }
        end)
    }
  end

  defp price_tier(nil, _median), do: "same"
  defp price_tier(_price, nil), do: "same"
  defp price_tier(price, median) when price < median, do: "cheap"
  defp price_tier(price, median) when price > median, do: "dear"
  defp price_tier(_price, _median), do: "same"

  @filter_fuels ~w(gasoline_95 gasoline_98 diesel_a diesel_premium charging)

  defp normalize_fuel(fuel) when fuel in @filter_fuels, do: fuel
  defp normalize_fuel(_fuel), do: "gasoline_95"

  defp filter_fuels, do: Charger.Prices.fuels() ++ [:charging]

  defp align_filters(%{fuel: fuel} = filters) do
    case place_index(fuel) do
      :loading ->
        filters

      index ->
        province = closest_label(filters.province, index.provinces)

        municipalities =
          if province == "", do: [], else: Map.get(index.by_province, province, [])

        %{
          filters
          | province: province,
            municipality: closest_label(filters.municipality, municipalities)
        }
    end
  end

  defp place_index("charging") do
    snapshot = Charger.Chargers.snapshot()
    if snapshot.status == :ready, do: place_index(snapshot.sites), else: :loading
  end

  defp place_index(fuel) when is_binary(fuel) do
    snapshot = Charger.Prices.Cache.snapshot()
    if snapshot.status == :ready, do: place_index(snapshot.stations), else: :loading
  end

  defp place_index(rows) when is_list(rows) do
    by_province =
      rows
      |> Enum.group_by(& &1.province, & &1.municipality)
      |> Map.new(fn {province, names} ->
        {province, names |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()}
      end)

    provinces =
      rows
      |> Enum.map(& &1.province)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    %{provinces: provinces, by_province: by_province}
  end

  defp closest_label("", _labels), do: ""

  defp closest_label(value, labels) do
    key = fold(value)
    Enum.find(labels, "", &(fold(&1) == key))
  end

  defp fold(text) do
    text
    |> to_string()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{M}/u, "")
    |> String.upcase()
  end

  defp blank(nil), do: ""
  defp blank(value), do: to_string(value)

  defp locales do
    [
      %{code: "uk", label: "UA"},
      %{code: "en", label: "EN"},
      %{code: "es", label: "ES"}
    ]
  end

  defp caption(result, _origin, :map, count) do
    gettext("Showing %{shown} of %{total} on the map.", shown: count, total: result.total)
  end

  defp caption(result, origin, :table, _count) do
    shown = length(result.stations)

    cond do
      origin ->
        gettext("Showing %{shown} of %{total}, nearest first.",
          shown: shown,
          total: result.total
        )

      result.fuel == :charging ->
        gettext("Showing %{shown} of %{total}, fastest first.",
          shown: shown,
          total: result.total
        )

      true ->
        gettext("Showing %{shown} of %{total}, cheapest first.",
          shown: shown,
          total: result.total
        )
    end
  end

  defp fuel_label(:gasoline_95), do: gettext("Gasoline 95 E5")
  defp fuel_label(:gasoline_98), do: gettext("Gasoline 98 E5")
  defp fuel_label(:diesel_a), do: gettext("Diesel A")
  defp fuel_label(:diesel_premium), do: gettext("Premium diesel")
  defp fuel_label(:charging), do: gettext("Electric vehicle charging")

  defp fuel_chip(:gasoline_95), do: "95"
  defp fuel_chip(:gasoline_98), do: "98"
  defp fuel_chip(:diesel_a), do: "B7"
  defp fuel_chip(:diesel_premium), do: "B7+"
  defp fuel_chip(:charging), do: "EV"

  defp fuel_short(:gasoline_95), do: "95"
  defp fuel_short(:gasoline_98), do: "98"
  defp fuel_short(:diesel_a), do: "B7"
  defp fuel_short(:diesel_premium), do: "B7+"

  defp fuel_bits(station) do
    Enum.flat_map([:gasoline_95, :gasoline_98, :diesel_a, :diesel_premium], fn fuel ->
      case Map.get(station.prices, fuel) do
        nil -> []
        price -> [%{fuel: fuel, price: price}]
      end
    end)
  end

  defp delta_class(delta) when delta < 0, do: "price-delta is-cheap"
  defp delta_class(delta) when delta > 0, do: "price-delta is-dear"
  defp delta_class(_delta), do: "price-delta is-same"

  defp updated_clock(result) do
    cond do
      result.status != :ready ->
        nil

      clock = Charger.Prices.source_clock(result.fecha) ->
        clock

      match?(%DateTime{}, result.fetched_at) ->
        result.fetched_at
        |> Charger.Prices.Schedule.to_madrid()
        |> Calendar.strftime("%H:%M")

      true ->
        nil
    end
  end

  defp column_label(:charging), do: gettext("Power")
  defp column_label(_fuel), do: gettext("Price")

  defp edge_label(:low, :charging), do: gettext("Slowest")
  defp edge_label(:high, :charging), do: gettext("Fastest")
  defp edge_label(:low, _fuel), do: gettext("Cheapest")
  defp edge_label(:high, _fuel), do: gettext("Most expensive")

  defp edge_value(value, :charging, locale), do: Charger.Chargers.format_power(value, locale)
  defp edge_value(value, _fuel, locale), do: money(value, locale)

  defp loading_text(:charging), do: gettext("Chargers are loading into the cache.")
  defp loading_text(_fuel), do: gettext("Prices are loading into the cache.")

  defp empty_cache_text(:charging), do: gettext("The charging catalog is empty.")

  defp empty_cache_text(_fuel),
    do: gettext("The price cache is empty. The hourly update has not succeeded yet.")

  defp plug_name(%{kind: :dc}), do: "DC"
  defp plug_name(%{kind: :ac}), do: "AC"
  defp plug_name(_plug), do: gettext("Charging")

  defp plug_title(%{count: count}) when count > 1,
    do: gettext("%{count} connectors", count: count)

  defp plug_title(_plug), do: nil

  defp brand_title(station), do: Map.get(station, :brand_title) || station.brand

  defp money(nil, _locale), do: "—"
  defp money(millis, locale), do: Charger.Prices.format_price(millis, locale)

  defp distance_text(nil, _locale), do: "—"

  defp distance_text(meters, locale) do
    gettext("%{distance} km", distance: Charger.Prices.format_kilometers(meters, locale))
  end

  defp schedule_text(station), do: Charger.Prices.Schedule.display(station.schedule)

  defp place(station) do
    [station.address, station.municipality]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end
end
