defmodule Storehouse.ReadTest do
  # The root is application config.
  use ExUnit.Case, async: false

  alias Storehouse.Local

  @fixtures Path.expand("../fixtures", __DIR__)
  @harbour Path.join(@fixtures, "harbour.jpg")

  # The local disk, with every read it is asked for sent to the test, and
  # a failure from the second chunk on, when asked.
  defmodule Watched do
    @behaviour Storehouse.Adapter

    @impl true
    defdelegate put(key, path, meta), to: Local
    @impl true
    defdelegate url(key), to: Local
    @impl true
    defdelegate delete(key), to: Local
    @impl true
    defdelegate head(key), to: Local

    @impl true
    def read_range(key, first, last) do
      send(Application.fetch_env!(:storehouse, :test_pid), {:read_range, first, last})

      if first > 0 and Application.get_env(:storehouse, :fail_after_first),
        do: {:error, :gone},
        else: Local.read_range(key, first, last)
    end
  end

  # A store that only stores.
  defmodule Blind do
    @behaviour Storehouse.Adapter

    @impl true
    def put(_key, _path, _meta), do: {:ok, "/blind"}
    @impl true
    def url(_key), do: "/blind"
    @impl true
    def delete(_key), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-read-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Local, root: root)
    Application.put_env(:storehouse, :test_pid, self())

    on_exit(fn ->
      Application.delete_env(:storehouse, Local)
      Application.delete_env(:storehouse, :test_pid)
      Application.delete_env(:storehouse, :fail_after_first)
      File.rm_rf!(root)
    end)

    {:ok, file} = Storehouse.store(@harbour)
    %{root: root, stored: file}
  end

  describe "head/2" do
    test "gives the size and type of a stored file, without reading it", %{stored: file} do
      assert Storehouse.head(file) ==
               {:ok, %{bytes: 35_367, content_type: "image/jpeg", checksum: nil}}

      assert Storehouse.head(file.key, adapter: Watched) == Storehouse.head(file)
      refute_received {:read_range, _first, _last}
    end

    test "refuses a missing file, a key that is not valid, and a store that cannot read" do
      assert Storehouse.head("2026/10/missing.png") == {:error, :enoent}
      assert Storehouse.head("../escape.png") == {:error, :invalid_key}
      assert Storehouse.head("2026/10/a.png", adapter: Blind) == {:error, :not_supported}
    end
  end

  describe "read/2" do
    test "gives the bytes of a file", %{stored: file} do
      assert Storehouse.read(file) == {:ok, File.read!(@harbour)}
    end

    test "refuses a file larger than :max_bytes before a byte of it is read", %{stored: file} do
      assert Storehouse.read(file.key, adapter: Watched, max_bytes: 35_366) ==
               {:error, {:too_large, 35_367}}

      refute_received {:read_range, _first, _last}

      assert {:ok, _bytes} = Storehouse.read(file.key, adapter: Watched, max_bytes: 35_367)
      assert_received {:read_range, 0, 35_366}
    end

    test "gives an empty file as it is, and refuses a missing one", %{root: root} do
      key = "2026/10/empty.txt"
      File.mkdir_p!(Path.join(root, "2026/10"))
      File.write!(Path.join(root, key), "")

      assert Storehouse.read(key) == {:ok, ""}
      assert Storehouse.read("2026/10/missing.png") == {:error, :enoent}
    end
  end

  describe "stream/2" do
    test "gives the file a chunk at a time, each read as the stream is taken", %{stored: file} do
      assert {:ok, stream} = Storehouse.stream(file.key, adapter: Watched, chunk_bytes: 10_000)
      refute_received {:read_range, _first, _last}

      chunks = Enum.to_list(stream)
      assert Enum.map(chunks, &byte_size/1) == [10_000, 10_000, 10_000, 5_367]
      assert IO.iodata_to_binary(chunks) == File.read!(@harbour)

      for {first, last} <- [{0, 9_999}, {10_000, 19_999}, {20_000, 29_999}, {30_000, 35_366}],
          do: assert_received({:read_range, ^first, ^last})
    end

    test "refuses a missing file and one larger than :max_bytes at once", %{stored: file} do
      assert Storehouse.stream("2026/10/missing.png") == {:error, :enoent}
      assert Storehouse.stream(file, max_bytes: 1_000) == {:error, {:too_large, 35_367}}
    end

    test "raises Storehouse.ReadError when the store fails halfway", %{stored: file} do
      Application.put_env(:storehouse, :fail_after_first, true)
      {:ok, stream} = Storehouse.stream(file.key, adapter: Watched, chunk_bytes: 10_000)

      error = assert_raise Storehouse.ReadError, fn -> Enum.to_list(stream) end
      assert error.key == file.key
      assert error.reason == :gone
    end

    test "ends where the file ends, when it is shorter than it was", %{root: root, stored: file} do
      {:ok, stream} = Storehouse.stream(file, chunk_bytes: 10_000)
      File.write!(Path.join(root, file.key), "shorter")

      assert IO.iodata_to_binary(Enum.to_list(stream)) == "shorter"
    end
  end

  describe "download/3" do
    test "writes the file to a path", %{stored: file} do
      path = Path.join(System.tmp_dir!(), "storehouse-download-#{System.unique_integer()}")
      on_exit(fn -> File.rm(path) end)

      assert Storehouse.download(file, path, chunk_bytes: 4_096) == :ok
      assert File.read!(path) == File.read!(@harbour)
    end

    test "leaves nothing at the path when the store fails halfway", %{stored: file} do
      Application.put_env(:storehouse, :fail_after_first, true)
      path = Path.join(System.tmp_dir!(), "storehouse-download-#{System.unique_integer()}")

      assert Storehouse.download(file.key, path, adapter: Watched, chunk_bytes: 10_000) ==
               {:error, :gone}

      refute File.exists?(path)
    end

    test "refuses a file larger than :max_bytes, and writes nothing", %{stored: file} do
      path = Path.join(System.tmp_dir!(), "storehouse-download-#{System.unique_integer()}")

      assert Storehouse.download(file, path, max_bytes: 10) == {:error, {:too_large, 35_367}}
      refute File.exists?(path)
    end
  end

  test "each read is a telemetry span", %{stored: file} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :read, :stop]])

    {:ok, _bytes} = Storehouse.read(file)

    key = file.key
    assert_received {[:storehouse, :read, :stop], ^ref, %{duration: _}, %{key: ^key, result: :ok}}
  end
end
