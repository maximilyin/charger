defmodule Charger.Reve.ScriptedSource do
  @moduledoc false

  @key {__MODULE__, :script}

  def fetch_page(page) when is_integer(page) do
    fun = :persistent_term.get(@key, &default/1)
    fun.(page)
  end

  def default(_page), do: {:error, :rate_limited}
end
