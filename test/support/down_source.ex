defmodule Charger.DownSource do
  @moduledoc false

  @key {__MODULE__, :fetches}

  def fetch do
    :persistent_term.put(@key, fetch_count() + 1)
    {:error, :down}
  end

  def fetch_count, do: :persistent_term.get(@key, 0)
end
