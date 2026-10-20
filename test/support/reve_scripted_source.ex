defmodule Charger.Reve.ScriptedSource do
  @moduledoc false

  @key {__MODULE__, :script}

  def fetch_page(kind, page) when is_integer(page) do
    fun = :persistent_term.get(@key, &default/2)
    fun.(kind, page)
  end

  def default(_kind, _page), do: {:error, :rate_limited}
end
