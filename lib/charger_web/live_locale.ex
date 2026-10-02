defmodule ChargerWeb.LiveLocale do
  @moduledoc false

  @locales ~w(uk en es)

  def on_mount(:default, _params, session, socket) do
    locale = session["locale"] || "uk"
    locale = if locale in @locales, do: locale, else: "uk"
    Gettext.put_locale(ChargerWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
end
