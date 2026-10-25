defmodule Storehouse.MemoryTest do
  use ExUnit.Case, async: true

  import Storehouse.Test

  alias Storehouse.Memory

  @fixtures Path.expand("../fixtures", __DIR__)
  @harbour Path.join(@fixtures, "harbour.jpg")

  setup do
    Memory.checkout()
  end

  test "stores, reads back, lists, copies and deletes" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory)
    assert file.url == "/memory/" <> file.key
    assert_stored(file.key)
    assert_stored(~r/harbour\.jpg\z/)

    assert Storehouse.read(file, adapter: Memory) == {:ok, File.read!(@harbour)}

    assert {:ok, %{bytes: 35_367, content_type: "image/jpeg", checksum: checksum}} =
             Storehouse.head(file, adapter: Memory)

    assert checksum == file.checksum
    assert Memory.checksum(file.key) == {:ok, file.checksum}

    {:ok, stream} = Storehouse.stream(file, adapter: Memory, chunk_bytes: 10_000)
    assert stream |> Enum.to_list() |> length() == 4

    assert :ok = Memory.copy(file.key, "copies/harbour.jpg")
    assert {:ok, entries} = Storehouse.list("copies/", adapter: Memory)
    assert [%{key: "copies/harbour.jpg", bytes: 35_367}] = Enum.to_list(entries)
    assert {:ok, every} = Storehouse.list("", adapter: Memory)

    assert every |> Enum.map(& &1.key) |> Enum.sort() ==
             Enum.sort([file.key, "copies/harbour.jpg"])

    assert {:ok, after_copies} = Storehouse.list("", adapter: Memory, after: "copies/harbour.jpg")

    assert Enum.map(after_copies, & &1.key) ==
             Enum.filter([file.key], &(&1 > "copies/harbour.jpg"))

    assert Storehouse.delete_prefix("copies/", adapter: Memory) == {:ok, 1}
    assert :ok = Storehouse.delete(file.key, adapter: Memory)
    refute_stored(file.key)
    assert stored_files() == []
  end

  test "a temporary file made permanent" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory, cache: true)
    assert Storehouse.cached?(file)

    {:ok, file} = Storehouse.promote(file, adapter: Memory)
    assert [%{key: key, content_type: "image/jpeg"}] = stored_files()
    assert key == file.key
  end

  test "an upload straight to the store, checked by its first bytes" do
    body = File.read!(@harbour)

    {:ok, upload} =
      Storehouse.presign_upload("harbour.jpg", "image/jpeg", byte_size(body), adapter: Memory)

    assert Memory.put_upload(upload, "too short") == 403
    assert Memory.put_upload(upload, body) == 200

    assert {:ok, file} = Storehouse.verify_upload(upload.key, adapter: Memory)
    assert file.width == 1200

    # A page sent as a photo is refused, and deleted.
    page = "<html><script>alert(1)</script></html>"

    {:ok, upload} =
      Storehouse.presign_upload("a.png", "image/png", byte_size(page), adapter: Memory)

    200 = Memory.put_upload(upload, page)

    assert Storehouse.verify_upload(upload.key, adapter: Memory) == {:error, :not_accepted}
    refute_stored(upload.key)
  end

  test "a streamed upload" do
    {:ok, stream} = Memory.stream_open("2026/10/a.txt", %{content_type: "text/plain"})
    {:ok, stream} = Memory.stream_write(stream, "one, ")
    {:ok, stream} = Memory.stream_write(stream, ["two"])
    assert {:ok, "/memory/2026/10/a.txt"} = Memory.stream_close(stream)

    assert Memory.get("2026/10/a.txt").body == "one, two"
    assert Memory.stream_open("2026/10/a.txt", %{}) == {:error, :eexist}
  end

  test "the next call of a callback fails, once" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory)

    Memory.fail_next(:delete, :unavailable)
    assert Storehouse.delete(file.key, adapter: Memory) == {:error, :unavailable}
    assert Storehouse.delete(file.key, adapter: Memory) == :ok

    Memory.fail_next(:put, :full)
    assert Storehouse.store(@harbour, adapter: Memory) == {:error, :full}
  end

  test "a task sees its test's files, and an allowed process does" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory)

    assert Task.await(Task.async(fn -> Memory.keys() end)) == [file.key]

    test = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(test, {:keys, Memory.keys()})
        end
      end)

    Memory.allow(self(), pid)
    send(pid, :go)
    assert_receive {:keys, [key]}
    assert key == file.key
  end

  test "refuses keys that are not valid" do
    assert Memory.put("../a.png", @harbour, %{}) == {:error, :invalid_key}
    assert Memory.read_range("../a.png", 0, 1) == {:error, :invalid_key}
    assert Storehouse.read("2026/10/none.png", adapter: Memory) == {:error, :enoent}
  end

  test "a test's files go when it ends" do
    test = self()

    {:ok, owner} =
      Task.start(fn ->
        Memory.checkout()
        Memory.put("2026/10/gone.txt", @harbour, %{})
        send(test, :stored)
      end)

    ref = Process.monitor(owner)
    assert_receive :stored
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    # The store sees the owner's exit, then removes its files.
    _sync = :sys.get_state(Memory)
    assert :ets.match(Memory.Files, {{owner, :_}, :_}) == []
  end
end

for n <- 1..2 do
  defmodule Module.concat(Storehouse.MemoryIsolationTest, "Case#{n}") do
    use ExUnit.Case, async: true

    @n n

    setup do
      Storehouse.Memory.checkout()
    end

    test "sees only its own file under a key another async test also writes" do
      path = Path.join(System.tmp_dir!(), "storehouse-memory-#{@n}-#{System.unique_integer()}")
      File.write!(path, "case #{@n}")
      on_exit(fn -> File.rm(path) end)

      for _round <- 1..50 do
        {:ok, _url} = Storehouse.Memory.put("shared/key.txt", path, %{content_type: "text/plain"})
        assert Storehouse.Memory.get("shared/key.txt").body == "case #{@n}"
        assert Storehouse.Memory.keys() == ["shared/key.txt"]
      end
    end
  end
end
