defmodule Storehouse.VariantsDeleteTest do
  # Variants configured for the app, as delete/2 reads them.
  use ExUnit.Case, async: false

  alias Storehouse.Memory

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    Memory.checkout()
    Application.put_env(:storehouse, Storehouse.Variants, presets: [thumb: [width: 32]])
    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.Variants) end)

    {:ok, file} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory, owner: "accounts/7")

    {:ok, thumb} = Storehouse.variant(file, :thumb, adapter: Memory)
    %{original: file, thumb: thumb}
  end

  test "deleted with their original", %{original: file, thumb: thumb} do
    assert {:ok, _} = Storehouse.head(thumb, adapter: Memory)
    assert :ok = Storehouse.delete(file.key, adapter: Memory)
    assert {:error, :enoent} = Storehouse.head(thumb, adapter: Memory)
  end

  test "deleted with a prefix of originals", %{thumb: thumb} do
    assert {:ok, 1} = Storehouse.delete_prefix("accounts/7/", adapter: Memory)
    assert {:error, :enoent} = Storehouse.head(thumb, adapter: Memory)
  end

  test "a variant deleted leaves its original", %{original: file, thumb: thumb} do
    assert :ok = Storehouse.delete(thumb.key, adapter: Memory)
    assert {:ok, _} = Storehouse.head(file, adapter: Memory)
  end
end
