defmodule Charger.CacheFileTest do
  use ExUnit.Case, async: true

  test "round trip keeps the body and the update time" do
    path = temp_path("round-trip")
    updated_at = ~U[2026-10-02 14:09:00Z]

    assert :ok = Charger.CacheFile.write(path, "payload-body", updated_at)
    assert {:ok, "payload-body", ^updated_at} = Charger.CacheFile.read(path)

    {:ok, contents} = File.read(path)
    assert contents == "updated_at 2026-10-02T14:09:00Z\npayload-body"
  end

  test "a body may contain newlines after the date line" do
    path = temp_path("newlines")
    updated_at = ~U[2026-10-02 14:09:00Z]

    assert :ok = Charger.CacheFile.write(path, "one\ntwo", updated_at)
    assert {:ok, "one\ntwo", ^updated_at} = Charger.CacheFile.read(path)
  end

  test "missing and damaged files are errors" do
    path = temp_path("missing")
    assert {:error, :enoent} = Charger.CacheFile.read(path)

    File.write!(path, "not a cache")
    assert {:error, :invalid} = Charger.CacheFile.read(path)
  end

  defp temp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "charger-cache-#{name}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    path
  end
end
