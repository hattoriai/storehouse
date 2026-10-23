defmodule Storehouse.ZipTest do
  use ExUnit.Case, async: true

  alias Storehouse.{Memory, Zip}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)
  @png Path.expand("../fixtures/small.png", __DIR__)

  setup do
    Memory.checkout()
    {:ok, photo} = Storehouse.store(@harbour, adapter: Memory)
    {:ok, small} = Storehouse.store(@png, adapter: Memory)
    %{photo: photo, small: small}
  end

  defp zipped(entries, opts \\ []) do
    {:ok, zip} = Zip.stream(entries, Keyword.put_new(opts, :adapter, Memory))
    IO.iodata_to_binary(Enum.to_list(zip))
  end

  defp unzipped(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, body} -> {List.to_string(name), body} end)
  end

  # `unzip -t`, where it is installed: every file's CRC checked.
  defp tested(zip) do
    if unzip = System.find_executable("unzip") do
      path = Path.join(System.tmp_dir!(), "zip-test-#{System.unique_integer([:positive])}.zip")
      File.write!(path, zip)
      {output, status} = System.cmd(unzip, ["-t", path], stderr_to_stdout: true)
      File.rm(path)
      assert status == 0, output
    end

    zip
  end

  test "stored files, binaries and streams, each as it was", %{photo: photo, small: small} do
    entries = [
      {"photos/harbour.jpg", {:stored, photo.key}},
      {"photos/small.png", {:stored, small.key}},
      {"README.txt", "Your photographs.\n"},
      {"empty.txt", ""},
      {"stories.json", {:stream, Stream.map(1..1_000, &"{\"n\": #{&1}}\n")}},
      {"ünïcode/naïve.txt", "é"}
    ]

    files = entries |> zipped() |> tested() |> unzipped()

    assert files["photos/harbour.jpg"] == File.read!(@harbour)
    assert files["photos/small.png"] == File.read!(@png)
    assert files["README.txt"] == "Your photographs.\n"
    assert files["empty.txt"] == ""
    assert files["stories.json"] =~ ~s({"n": 1000})
    assert files["ünïcode/naïve.txt"] == "é"
  end

  test "its size is known before it is made, unless a stream's is not", %{photo: photo} do
    entries = [{"a.jpg", {:stored, photo.key}}, {"b.txt", "bee"}]
    assert Zip.size(entries, adapter: Memory) == {:ok, byte_size(zipped(entries))}
    assert Zip.size([{"s", {:stream, []}} | entries], adapter: Memory) == {:error, :unknown_size}
    assert Zip.size([], adapter: Memory) == {:ok, byte_size(zipped([]))}
  end

  test "more than 65,535 files: ZIP64's end of the directory" do
    entries = for i <- 1..70_000, do: {"f/#{i}.txt", "#{i}"}
    zip = entries |> zipped() |> tested()

    assert map_size(unzipped(zip)) == 70_000
    assert Zip.size(entries) == {:ok, byte_size(zip)}
  end

  test "a name that could leave the folder, or twice, is refused" do
    for name <- ["/etc/passwd", "../up.txt", "a/../../b", "a\\b", "", "a//b", "nul\0"],
        do: assert(Zip.stream([{name, "x"}]) == {:error, {:invalid_name, name}})

    assert Zip.stream([{"a", "1"}, {"a", "2"}]) == {:error, {:duplicate_name, "a"}}
    assert Zip.stream([{"a", 42}]) == {:error, {:invalid_entry, {"a", 42}}}

    assert Zip.stream([{"a", {:stored, "none.png"}}], adapter: Memory) ==
             {:error, {"none.png", :enoent}}
  end

  test "into the store, as it is made, a Storehouse.File", %{photo: photo} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :zip, :stop]])
    entries = [{"harbour.jpg", {:stored, photo.key}}, {"notes.txt", "notes"}]

    assert {:ok, %Storehouse.File{key: "exports/1.zip", content_type: "application/zip"} = file} =
             Zip.store(entries, "exports/1.zip", adapter: Memory)

    {:ok, zip} = Storehouse.read(file.key, adapter: Memory)
    assert file.bytes == byte_size(zip)
    assert file.checksum == Base.encode64(:crypto.hash(:sha256, zip))
    assert unzipped(tested(zip))["harbour.jpg"] == File.read!(@harbour)

    assert_received {[:storehouse, :zip, :stop], ^ref, _measures, %{entries: 2, bytes: bytes}}
    assert bytes == file.bytes
  end

  test "a stored file not the size it was stops the zip, and nothing is kept", %{small: small} do
    {:ok, zip} = Zip.stream([{"small.png", {:stored, small.key}}], adapter: Memory)

    # Replaced, larger, between the zip's plan and its making.
    path = Path.join(System.tmp_dir!(), "zip-larger-#{System.unique_integer([:positive])}")
    File.write!(path, File.read!(@harbour))
    {:ok, _url} = Memory.put(small.key, path, %{content_type: "image/png"})

    assert_raise ArgumentError, ~r/small.png is larger than its 77 bytes/, fn ->
      Enum.to_list(zip)
    end

    # Smaller than it was: cut short, not padded.
    {:ok, zip} = Zip.stream([{"small.png", {:stored, small.key}}], adapter: Memory)
    File.write!(path, "tiny")
    {:ok, _url} = Memory.put(small.key, path, %{content_type: "image/png"})
    File.rm(path)
    assert_raise ArgumentError, ~r/small.png is 4 bytes, not 35367/, fn -> Enum.to_list(zip) end
  end

  test "store/3 gives a stream's error, and leaves nothing" do
    broken =
      Stream.map([1, 2], fn
        2 -> raise Storehouse.ReadError, key: "k", reason: :gone
        n -> "#{n}"
      end)

    assert Zip.store([{"a.txt", {:stream, broken}}], "exports/broken.zip", adapter: Memory) ==
             {:error, :gone}

    assert Storehouse.head("exports/broken.zip", adapter: Memory) == {:error, :enoent}
  end

  @tag :large
  @tag :tmp_dir
  @tag timeout: 600_000
  test "past 4 GB: files, offsets and the directory in ZIP64", %{tmp_dir: dir} do
    Application.put_env(:storehouse, Storehouse.Local, root: dir)
    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.Local) end)
    # A stored file of 4.5 GB, sparse on the disk.
    File.mkdir_p!(Path.join(dir, "big"))

    {_out, 0} =
      System.cmd("truncate", ["-s", "4500000000", Path.join([dir, "big", "sparse.bin"])])

    zeros = :binary.copy(<<0>>, 4_194_304)

    entries = [
      {"first.txt", "first"},
      {"sparse.bin", {:stored, "big/sparse.bin"}},
      {"streamed.bin", {:stream, Stream.repeatedly(fn -> zeros end) |> Stream.take(1_050)}},
      {"last.txt", "last"}
    ]

    {:ok, zip} = Zip.stream(entries, adapter: Storehouse.Local)
    path = Path.join(dir, "big.zip")
    File.open!(path, [:write, :raw], fn io -> Enum.each(zip, &(:ok = :file.write(io, &1))) end)
    File.rm!(Path.join([dir, "big", "sparse.bin"]))

    assert {output, 0} = System.cmd("unzip", ["-t", path], stderr_to_stdout: true)
    assert output =~ "No errors detected"
  end
end
