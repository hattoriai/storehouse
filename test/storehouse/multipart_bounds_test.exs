defmodule Storehouse.MultipartBoundsTest do
  # The sizes a browser gives about an upload in parts, never trusted for
  # more than the upload is: no store needed.
  use ExUnit.Case, async: true

  defmodule Store do
    # An upload whose first part, of one byte, is all the store has.
    def multipart_parts(_key, _id), do: {:ok, [%{number: 1, bytes: 1, etag: "e", checksum: nil}]}
    def multipart_complete(_key, _id, _parts), do: {:error, :not_expected}

    def multipart_sign(_key, _id, number, opts),
      do: {:ok, %{method: "PUT", url: "https://store/#{number}/#{opts[:bytes]}", headers: %{}}}
  end

  @key "o/2026/10/0b6f4c2e-5f0a-4d4c-9a51-2f0e7d1c3b9a-a.bin"

  test "a size past S3's largest, or the endpoint's, is refused before the store is asked" do
    # A list as long as the size would take the node's memory.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 10_000_000, kill: true, error_logger: false})
        exit(Storehouse.complete_multipart(@key, "id", 10 ** 20, adapter: Store))
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:error, :too_large}}, 1_000

    assert Storehouse.complete_multipart(@key, "id", 100, adapter: Store, max_bytes: 10) ==
             {:error, :too_large}

    assert Storehouse.complete_multipart(@key, "id", -1, adapter: Store) ==
             {:error, :invalid_part}
  end

  test "more parts than S3 takes, by the first part's size, are not counted" do
    # 1 TiB in parts of one byte: refused at once.
    assert {:error, {:wrong_size, 1}} =
             Storehouse.complete_multipart(@key, "id", 1_099_511_627_776, adapter: Store)
  end

  test "parts signed with their size, and none past the upload's last" do
    sizes = [bytes: 12, part_bytes: 5]

    assert {:ok, signed} =
             Storehouse.presign_parts(@key, "id", [1, 2, 3], [adapter: Store] ++ sizes)

    assert Enum.map(signed, & &1.url) == [
             "https://store/1/5",
             "https://store/2/5",
             "https://store/3/2"
           ]

    assert Storehouse.presign_parts(@key, "id", [4], [adapter: Store] ++ sizes) ==
             {:error, :invalid_part}

    assert Storehouse.presign_parts(@key, "id", [1], adapter: Store, bytes: 12) ==
             {:error, :invalid_part}
  end
end
