defmodule ChargerWeb.LocaleController do
  use ChargerWeb, :controller

  @locales ~w(uk en es)

  def switch(conn, %{"locale" => locale} = params) when locale in @locales do
    query =
      for key <- ~w(province municipality fuel q),
          value = params[key],
          value not in [nil, ""],
          do: {key, value}

    destination = if query == [], do: ~p"/", else: ~p"/?#{query}"

    conn
    |> put_session(:locale, locale)
    |> redirect(to: destination)
  end

  def switch(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
