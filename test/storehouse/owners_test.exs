defmodule Storehouse.OwnersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Storehouse.Memory

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)
  @bytes 35_367

  doctest Storehouse, only: [owner_key: 2, owns?: 2]

  setup do
    Memory.checkout()
  end

  defp store(opts), do: Storehouse.store(@harbour, Keyword.put(opts, :adapter, Memory))

  test "a file is stored under its owner's prefix" do
    {:ok, file} = store(owner: "accounts/42")
    assert "accounts/42/" <> _rest = file.key
    assert Storehouse.owns?("accounts/42", file.key)

    {:ok, file} = store(owner: 7, cache: true)
    assert "cache/7/" <> _rest = file.key
    assert Storehouse.owns?(7, file.key)

    {:ok, permanent} = Storehouse.promote(file, adapter: Memory)
    assert "7/" <> _rest = permanent.key
    assert Storehouse.owns?(7, permanent.key)
  end

  test "an owner that could leave its prefix is refused, and nothing stored" do
    for owner <- ["../7", "a//b", "", "/", -1, %{}, "a b"] do
      assert store(owner: owner) == {:error, :invalid_owner}, inspect(owner)
    end

    assert Memory.keys() == []
  end

  test "an owner owns only what is under its prefix" do
    refute Storehouse.owns?("42", "421/2026/10/a.png")
    refute Storehouse.owns?("42", "4/2/2026/10/a.png")
    refute Storehouse.owns?("42", "42")
    refute Storehouse.owns?("42", "42/../7/a.png")
    refute Storehouse.owns?("42", "x/42/a.png")
    refute Storehouse.owns?("../42", "../42/a.png")
    assert Storehouse.owns?("42", "42/a.png")
  end

  property "no key under another owner's prefix is owned" do
    check all(
            owner <- integer(1..10_000),
            other <- integer(1..10_000),
            other != owner,
            rest <- string(:alphanumeric, min_length: 1)
          ) do
      refute Storehouse.owns?(owner, "#{other}/#{rest}")
      refute Storehouse.owns?(owner, "cache/#{other}/#{rest}")
      refute Storehouse.owns?(owner, "#{owner}#{rest}/x")
    end
  end

  test "a file larger than the room left is refused, and nothing stored" do
    assert store(room: @bytes - 1) == {:error, :storage_full}
    assert Memory.keys() == []
    assert {:ok, _file} = store(room: @bytes)
    assert {:ok, _file} = store(room: :infinity)
  end

  describe "uploads straight to the store" do
    defp upload(opts) do
      body = File.read!(@harbour)
      opts = Keyword.put(opts, :adapter, Memory)

      with {:ok, upload} <-
             Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body), opts) do
        200 = Memory.put_upload(upload, body)
        {:ok, upload}
      end
    end

    test "presigned under the owner, and refused past the room" do
      {:ok, upload} = upload(owner: "accounts/42")
      assert Storehouse.owns?("accounts/42", upload.key)
      assert upload(room: 10) == {:error, :storage_full}
    end

    test "another's file is refused at verify, and left where it is" do
      {:ok, upload} = upload(owner: "accounts/7")

      assert Storehouse.verify_upload(upload.key, adapter: Memory, owner: "accounts/42") ==
               {:error, :not_owner}

      assert upload.key in Memory.keys()

      assert {:ok, _file} =
               Storehouse.verify_upload(upload.key, adapter: Memory, owner: "accounts/7")
    end

    test "the size the store gives, not the browser's, is counted against the room" do
      {:ok, upload} = upload(owner: 42)

      assert Storehouse.verify_upload(upload.key, adapter: Memory, owner: 42, room: @bytes - 1) ==
               {:error, :storage_full}

      refute upload.key in Memory.keys()
    end
  end

  test "an owner's usage, and its files deleted together" do
    {:ok, _file} = store(owner: 42)
    {:ok, _file} = store(owner: 42)
    {:ok, _file} = store(owner: 421)

    assert Storehouse.usage(42, adapter: Memory) == {:ok, %{bytes: 2 * @bytes, files: 2}}
    assert Storehouse.delete_prefix("42/", adapter: Memory) == {:ok, 2}
    assert Storehouse.usage(42, adapter: Memory) == {:ok, %{bytes: 0, files: 0}}
    assert Storehouse.usage(421, adapter: Memory) == {:ok, %{bytes: @bytes, files: 1}}
    assert Storehouse.usage("../x", adapter: Memory) == {:error, :invalid_owner}
  end
end
