defmodule Charger.Chargers.Ripree do
  @moduledoc """
  Daily public export of Spanish charging installations.

  The catalog page posts JSON and returns a UTF-16 CSV. There is no API key.
  """

  @url "https://energia.serviciosmin.gob.es/Ripree/ExportarInstalaciones/GenerarExcel"

  def fetch do
    case Req.post(@url,
           json: %{"model" => nil, "soloConsolidado" => true},
           receive_timeout: 180_000,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
