defmodule ChargerWeb.CatalogLiveTest do
  use ChargerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "lists cached stations in Ukrainian by default", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Пальне в Іспанії"
    assert html =~ "Провінція"
    assert has_element?(view, ".catalog-locales a", "UA")
    assert has_element?(view, ".catalog-locales a", "EN")
    assert has_element?(view, ".catalog-locales a", "ES")
    assert has_element?(view, "#stations .hero-map-pin")
    refute html =~ "Зведення міністерства"
    assert has_element?(view, "#station-count", "29")
    assert has_element?(view, "#stat-cheapest")
    assert has_element?(view, "aside #filters")
    assert has_element?(view, "#stations")
    assert has_element?(view, "#catalog-updated", "Оновлено о 08:36")
    refute html =~ "Лише загальнодоступні"

    assert has_element?(
             view,
             "a[href='https://www.google.com/maps/search/?api=1&query=40.432861,-3.724194']"
           )
  end

  test "filters by province", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#filters", %{filters: %{province: "BARCELONA"}})
      |> render_change()

    assert html =~ "BP"
    assert html =~ "AVENIDA DIAGONAL, 100"
    refute html =~ "PASEO MORET"
    assert has_element?(view, "#station-count", "1")
  end

  test "shows the median gap, the other fuels, and a 24 hour mark", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#filters", %{filters: %{province: "MADRID"}})
    |> render_change()

    assert has_element?(view, "#station-20001 .price-delta.is-cheap", "−0,055 €")
    assert has_element?(view, "#station-10943 .price-delta.is-dear", "+0,055 €")
    assert has_element?(view, "#station-10943 .fuel-line", "B7")
    assert has_element?(view, "#station-10943 .fuel-line", "1,994 €")
    assert has_element?(view, "#station-20001 .schedule", "24H")
    assert has_element?(view, "#station-10943 .schedule", "08:00-21:00")
    refute render(view) =~ "Цілодобово"
  end

  test "keeps filters in the address when switching language", %{conn: conn} do
    conn = get(conn, ~p"/")
    {:ok, view, _html} = live(conn)

    view |> element("#fuel-diesel_a") |> render_click()

    view
    |> form("#filters", %{filters: %{province: "MADRID", q: "cepsa"}})
    |> render_change()

    assert has_element?(
             view,
             ".catalog-locales a[href='/locale/en?province=MADRID&fuel=diesel_a&q=cepsa']",
             "EN"
           )

    conn = get(recycle(conn), ~p"/locale/en?province=MADRID&fuel=diesel_a&q=cepsa")
    assert redirected_to(conn) == ~p"/?province=MADRID&fuel=diesel_a&q=cepsa"

    {:ok, view, html} = live(recycle(conn), redirected_to(conn))

    assert html =~ "Fuel in Spain"
    assert html =~ "CEPSA"
    refute html =~ "REPSOL"
    assert has_element?(view, "#filters option[selected][value='MADRID']")
    assert has_element?(view, "#fuel-diesel_a.is-active")
    assert has_element?(view, "input[name='filters[q]'][value='cepsa']")
  end

  test "switches to English and Spanish", %{conn: conn} do
    conn = get(conn, ~p"/locale/en")
    assert redirected_to(conn) == ~p"/"

    {:ok, _view, html} = live(recycle(conn), ~p"/")

    assert html =~ "Fuel in Spain"
    assert html =~ "Province"
    assert html =~ "€1."

    conn = get(recycle(conn), ~p"/locale/es")
    {:ok, _view, html} = live(recycle(conn), ~p"/")

    assert html =~ "Carburante en España"
    assert html =~ "Provincia"
    assert html =~ "1,"
  end

  test "opens a bookmarked filter address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?province=BARCELONA&fuel=gasoline_95")

    assert has_element?(view, "#station-count", "1")
    assert has_element?(view, "#station-30001")
    assert has_element?(view, "#fuel-gasoline_95.is-active")
  end

  test "switches fuel from a chip and can reset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#fuel-diesel_a") |> render_click()

    assert_patch(view, ~p"/?fuel=diesel_a")
    assert has_element?(view, "#fuel-diesel_a.is-active")
    refute has_element?(view, "#filters select[name='filters[fuel]']")

    view |> element("#reset-filters") |> render_click()

    assert_patch(view, ~p"/")
    assert has_element?(view, "#fuel-gasoline_95.is-active")
  end

  test "shows the next page of an already filtered list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#station-40003")

    view |> element("#show-more") |> render_click()

    assert has_element?(view, "#station-40003")
    assert has_element?(view, "#station-count", "29")
  end

  test "sorts from a point and shows kilometres", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?province=MADRID")

    view
    |> element("#near-me")
    |> render_hook("near_me", %{"lat" => 40.44, "lng" => -3.72})

    assert has_element?(view, "#near-me.is-active")
    assert has_element?(view, "#station-20001 .distance", "км")
    assert has_element?(view, "#catalog-caption", "найближчі")

    view |> element("#near-me") |> render_hook("near_me", %{"clear" => true})

    refute has_element?(view, "#station-20001 .distance")
  end

  test "shows charging stations in the same table", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?fuel=charging&province=MADRID")

    assert has_element?(view, "#fuel-charging.is-active")
    assert has_element?(view, "#filters option[selected]", "Madrid")
    assert has_element?(view, "#station-count", "1")
    assert has_element?(view, "#station-SITE-A .price-main", "50 kW")
    assert has_element?(view, "#station-SITE-A .fuel-line", "DC")
    assert has_element?(view, "#station-SITE-A .fuel-line", "7,4 kW")
    assert has_element?(view, "#station-SITE-A .brand", "REPSOL")
    assert has_element?(view, "#station-SITE-A .schedule", "24H")
    assert has_element?(view, "#stat-dearest", "50 kW")
    assert has_element?(view, "#catalog-caption", "найшвидші")
    refute has_element?(view, "#station-SITE-B")

    assert has_element?(
             view,
             "a[href='https://www.google.com/maps/search/?api=1&query=40.432861,-3.724194']"
           )
  end
end
