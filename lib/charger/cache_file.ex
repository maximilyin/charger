defmodule Charger.CacheFile do
  @moduledoc """
  Last successful API body, kept next to the time it was saved.

  The first line is `updated_at <ISO8601>`. The rest of the file is the
  response. A start that cannot reach the API reads this file into ETS.
  """

  def write(path, body, %DateTime{} = updated_at) when is_binary(body) do
    updated_at = DateTime.truncate(updated_at, :second)
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(temporary, ["updated_at ", DateTime.to_iso8601(updated_at), "\n", body]),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  def read(path) do
    with {:ok, contents} <- File.read(path) do
      split(contents)
    end
  end

  defp split(contents) do
    case :binary.split(contents, "\n") do
      ["updated_at " <> stamp, body] ->
        case DateTime.from_iso8601(stamp) do
          {:ok, updated_at, _offset} -> {:ok, body, updated_at}
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end
end
