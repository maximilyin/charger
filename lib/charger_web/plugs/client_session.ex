defmodule ChargerWeb.Plugs.ClientSession do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    id =
      case get_session(conn, :client_id) do
        id when is_binary(id) and id != "" -> id
        _ -> Charger.Sessions.new_id()
      end

    Charger.Sessions.ensure(id)

    conn
    |> put_session(:client_id, id)
    |> assign(:client_id, id)
  end
end
