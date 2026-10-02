defmodule ChargerWeb.Plugs.Locale do
  @moduledoc false

  @locales ~w(uk en es)

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = Plug.Conn.get_session(conn, :locale) || "uk"
    locale = if locale in @locales, do: locale, else: "uk"
    Gettext.put_locale(ChargerWeb.Gettext, locale)
    Plug.Conn.assign(conn, :locale, locale)
  end
end
