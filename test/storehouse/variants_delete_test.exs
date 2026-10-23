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

  test "swept with their expired original, and refused once it is past its time" do
    {:ok, file} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory, expires_in: 1)

    {:ok, thumb} = Storehouse.variant(file, :thumb, adapter: Memory)

    # Past its time, before the sweep: no variant of it is given.
    expired = String.replace(file.key, ~r{/(\d+)/}, "/1/", global: false)
    assert {:error, :enoent} = Storehouse.variant(expired, :thumb, adapter: Memory)

    Process.sleep(1_100)
    assert {:error, :enoent} = Storehouse.variant(file, :thumb, adapter: Memory)
    assert {:ok, 1} = Storehouse.Sweeper.sweep(adapter: Memory)
    assert {:error, :enoent} = Storehouse.head(file, adapter: Memory)
    assert {:error, :enoent} = Storehouse.head(thumb, adapter: Memory)
  end

  test "a temporary file's variants go when it is made permanent" do
    {:ok, cached} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory, cache: true)

    {:ok, thumb} = Storehouse.variant(cached, :thumb, adapter: Memory)
    {:ok, _permanent} = Storehouse.promote(cached, adapter: Memory)
    assert {:error, :enoent} = Storehouse.head(thumb, adapter: Memory)
  end

  defmodule Slow do
    # A renderer that waits for the test before it draws.
    def render(source, destination, _variant, _opts) do
      send(:variants_delete_test, {:rendering, self()})

      receive do
        :go -> File.cp(source, destination)
      end
    end
  end

  test "an original deleted while its variant is drawn: the variant is not kept" do
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "small.png"), adapter: Memory)
    Process.register(self(), :variants_delete_test)
    task = Task.async(fn -> Storehouse.variant(file, :thumb, adapter: Memory, renderer: Slow) end)

    assert_receive {:rendering, renderer}
    :ok = Storehouse.delete(file.key, adapter: Memory)
    send(renderer, :go)

    assert {:error, :enoent} = Task.await(task)
    assert Enum.filter(Memory.keys(), &String.starts_with?(&1, "variants/#{file.key}/")) == []
  end
end
