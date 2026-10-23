defmodule Storehouse.ArchiveTest do
  use ExUnit.Case, async: true

  alias Storehouse.{Archive, Memory}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)
  @png Path.expand("../fixtures/small.png", __DIR__)
  @text String.duplicate("a line of an export, the same again\n", 5_000)

  setup do
    Memory.checkout()
    {:ok, photo} = Storehouse.store(@harbour, adapter: Memory)
    {:ok, small} = Storehouse.store(@png, adapter: Memory)
    %{photo: photo, small: small}
  end

  defp made(entries, opts \\ []) do
    {:ok, archive} = Archive.stream(entries, Keyword.put_new(opts, :adapter, Memory))
    IO.iodata_to_binary(Enum.to_list(archive))
  end

  defp unzipped(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, body} -> {List.to_string(name), body} end)
  end

  # The method of each file, as the zip's central directory says.
  defp methods(zip) do
    {:ok, [_comment | files]} = :zip.list_dir(zip)

    for {:zip_file, name, _info, _comment, _offset, size} <- files,
        into: %{},
        do: {List.to_string(name), size}
  end

  # The files of a zip read as a reader reads it as it comes, from each
  # local header and the stored blocks after it, never the central
  # directory. (Only the stored blocks this writer makes.)
  defp forward(
         <<"PK", 3, 4, _version::16, _flags::16, 8::little-16, _::binary-16, name_size::little-16,
           extra_size::little-16, rest::binary>>
       ) do
    <<name::binary-size(^name_size), _extra::binary-size(^extra_size), data::binary>> = rest
    {bytes, rest} = stored_blocks(data, [])
    <<"PK", 7, 8, _crc::32, _sizes::64, rest::binary>> = rest
    [{name, bytes} | forward(rest)]
  end

  defp forward(<<"PK", 1, 2, _::binary>>), do: []

  defp stored_blocks(<<final, size::little-16, _nsize::16, rest::binary>>, out) do
    <<bytes::binary-size(^size), rest::binary>> = rest
    out = [bytes | out]

    if final == 1,
      do: {IO.iodata_to_binary(Enum.reverse(out)), rest},
      else: stored_blocks(rest, out)
  end

  # `unzip -t`, where it is installed: every file's CRC checked.
  defp tested(zip) do
    if unzip = System.find_executable("unzip") do
      path =
        Path.join(System.tmp_dir!(), "archive-test-#{System.unique_integer([:positive])}.zip")

      File.write!(path, zip)
      {output, status} = System.cmd(unzip, ["-t", path], stderr_to_stdout: true)
      File.rm(path)
      assert status == 0, output
    end

    zip
  end

  describe "zip" do
    test "stored files, binaries, functions and streams, each as it was", %{
      photo: photo,
      small: small
    } do
      entries = [
        {"photos/harbour.jpg", {:stored, photo.key}},
        {"photos/small.png", {:stored, small.key}},
        {"export.csv", @text},
        {"empty.txt", ""},
        {"made.json", {:call, {String, :duplicate, ["{}\n", 1_000]}}},
        {"stories.jsonl", {:stream, Stream.map(1..1_000, &"{\"n\": #{&1}}\n")}},
        {"ünïcode/naïve.txt", "é"}
      ]

      files = entries |> made() |> tested() |> unzipped()

      assert files["photos/harbour.jpg"] == File.read!(@harbour)
      assert files["photos/small.png"] == File.read!(@png)
      assert files["export.csv"] == @text
      assert files["empty.txt"] == ""
      assert files["made.json"] == String.duplicate("{}\n", 1_000)
      assert files["stories.jsonl"] =~ ~s({"n": 1000})
      assert files["ünïcode/naïve.txt"] == "é"
    end

    test "by default, what shrinks is compressed, and photographs are stored as they are", %{
      photo: photo
    } do
      entries = [{"harbour.jpg", {:stored, photo.key}}, {"export.csv", @text}]
      zip = entries |> made() |> tested()

      sizes = methods(zip)
      # As it is, in one stored block: five bytes that say its size.
      assert sizes["harbour.jpg"] == File.stat!(@harbour).size + 5
      assert sizes["export.csv"] < byte_size(@text) / 20
      assert byte_size(zip) < byte_size(@text) / 2

      # :none stores all, :compress deflates all: the same bytes back.
      none = made(entries, compression: :none)
      assert byte_size(none) > byte_size(@text)

      assert unzipped(tested(made(entries, compression: :compress)))["harbour.jpg"] ==
               File.read!(@harbour)
    end

    test "a file stored as it is ends where its blocks say, whatever its bytes are" do
      # A photograph whose bytes end like a file in a zip, and start another.
      jpeg = <<0xFF, 0xD8, 0xFF, 0xD9>>
      fake_end = <<"PK", 7, 8, :erlang.crc32(jpeg)::little-32, 4::little-32, 4::little-32>>

      fake_start =
        <<"PK", 3, 4, 20::little-16, 0::16, 0::16, 0::32, :erlang.crc32("INJECTED")::little-32,
          8::little-32, 8::little-32, 12::little-16, 0::16>> <> "injected.txt" <> "INJECTED"

      photo = jpeg <> fake_end <> fake_start <> :binary.copy(<<0>>, 100_000)
      zip = made([{"a/photo.jpg", photo}, {"b/readme.txt", "ok"}], compression: :none)

      # Read as it comes, a file after the other: the two there are.
      assert forward(zip) == [{"a/photo.jpg", photo}, {"b/readme.txt", "ok"}]
      assert unzipped(tested(zip)) == %{"a/photo.jpg" => photo, "b/readme.txt" => "ok"}
    end

    test "its size before it is made: exact when nothing is compressed", %{photo: photo} do
      entries = [{"a.jpg", {:stored, photo.key}}, {"b.txt", "bee"}]

      assert Archive.size(entries, adapter: Memory, compression: :none) ==
               {:ok, byte_size(made(entries, compression: :none))}

      assert Archive.size(entries, adapter: Memory, compression: :none, password: "p") ==
               {:ok, byte_size(made(entries, compression: :none, password: "p"))}

      assert {:about, about} = Archive.size(entries, adapter: Memory)
      assert about >= byte_size(made(entries))

      assert Archive.size([{"s", {:stream, []}} | entries], adapter: Memory) ==
               {:error, :unknown_size}
    end

    test "more than 65,535 files: ZIP64's end of the directory" do
      entries = for i <- 1..70_000, do: {"f/#{i}.txt", "#{i}"}
      zip = entries |> made(compression: :none) |> tested()

      assert map_size(unzipped(zip)) == 70_000
      assert Archive.size(entries, compression: :none) == {:ok, byte_size(zip)}
    end

    @tag :sevenzip
    @tag :tmp_dir
    test "encrypted with AES-256: 7-Zip opens it with its password, and not without", %{
      photo: photo,
      tmp_dir: dir
    } do
      entries = [{"harbour.jpg", {:stored, photo.key}}, {"export.csv", @text}, {"empty.txt", ""}]
      zip = made(entries, password: "s3cret pässword")
      path = Path.join(dir, "secret.zip")
      File.write!(path, zip)

      refute zip =~ "a line of an export"
      assert {_out, 0} = System.cmd("7z", ["x", "-y", "-o#{dir}/out", "-ps3cret pässword", path])
      assert File.read!(Path.join([dir, "out", "export.csv"])) == @text
      assert File.read!(Path.join([dir, "out", "harbour.jpg"])) == File.read!(@harbour)

      assert {output, status} = System.cmd("7z", ["t", "-pwrong", path], stderr_to_stdout: true)
      assert status != 0 and output =~ "Wrong password"
    end
  end

  describe "tar" do
    defp untarred(tar) do
      {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory, :compressed])
      Map.new(files, fn {name, body} -> {List.to_string(name), body} end)
    end

    test "files as they were, long and UTF-8 names in pax headers, and its exact size", %{
      photo: photo
    } do
      long = String.duplicate("a-long-folder/", 12) <> "ünïcode.json"
      entries = [{"harbour.jpg", {:stored, photo.key}}, {"export.csv", @text}, {long, "{}"}]

      tar = made(entries, format: :tar, compression: :none)
      files = untarred(tar)

      assert files["harbour.jpg"] == File.read!(@harbour)
      assert files["export.csv"] == @text
      assert files[long] == "{}"

      assert Archive.size(entries, adapter: Memory, format: :tar, compression: :none) ==
               {:ok, byte_size(tar)}

      if tar_cmd = System.find_executable("tar") do
        path =
          Path.join(System.tmp_dir!(), "archive-test-#{System.unique_integer([:positive])}.tar")

        File.write!(path, tar)
        {listing, 0} = System.cmd(tar_cmd, ["tf", path])
        File.rm(path)
        assert long in String.split(listing, "\n")
      end
    end

    test "gzipped when most of it shrinks, or asked", %{photo: photo} do
      gz = made([{"export.csv", @text}], format: :tar)
      assert <<0x1F, 0x8B, _rest::binary>> = gz
      assert untarred(gz)["export.csv"] == @text

      photos = made([{"harbour.jpg", {:stored, photo.key}}], format: :tar)
      refute match?(<<0x1F, 0x8B, _rest::binary>>, photos)

      assert <<0x1F, 0x8B, _::binary>> =
               made([{"harbour.jpg", {:stored, photo.key}}], format: :tar, compression: :compress)
    end

    test "a file of unknown size, or a password, is refused" do
      assert_raise ArgumentError, ~r/size/, fn ->
        made([{"s.txt", {:stream, ["x"]}}], format: :tar)
      end

      assert_raise ArgumentError, ~r/not encrypted/, fn ->
        made([{"a.txt", "x"}], format: :tar, password: "p")
      end
    end
  end

  describe "the format" do
    defmodule Lines do
      @moduledoc false
      # A format of a test's own: each file's name, then its bytes.
      @behaviour Storehouse.Archive.Format

      @impl true
      def stream(entries, _opts),
        do: Stream.flat_map(entries, &Stream.concat([[&1.name, "\n"], &1.data.()]))

      @impl true
      def size(_entries, _opts), do: :unknown
      @impl true
      def bound(entry, _opts), do: byte_size(entry.name) + 1 + entry.size
      @impl true
      def end_bound(_count, _opts), do: 0
      @impl true
      def content_type(_entries, _opts), do: "text/plain"
    end

    test "one of the app's, or an unknown one" do
      assert made([{"a.txt", "one"}, {"b.txt", "two"}], format: Lines) ==
               "a.txt\none" <> "b.txt\ntwo"

      assert Archive.stream([{"a.txt", "x"}], format: :rar) == {:error, {:unknown_format, :rar}}
    end
  end

  describe "names" do
    test "a name that could leave the folder, or twice, is refused" do
      for name <- ["/etc/passwd", "../up.txt", "a/../../b", "a\\b", "", "a//b", "nul\0"],
          do: assert(Archive.stream([{name, "x"}]) == {:error, {:invalid_name, name}})

      assert Archive.stream([{"a", "1"}, {"a", "2"}]) == {:error, {:duplicate_name, "a"}}
      assert Archive.stream([{"a", 42}]) == {:error, {:invalid_entry, {"a", 42}}}

      assert Archive.stream([{"a", {:stored, "none.png"}}], adapter: Memory) ==
               {:error, {"none.png", :enoent}}
    end
  end

  describe "store/3" do
    test "into the store as it is made: a Storehouse.File, its checksum, and telemetry", %{
      photo: photo
    } do
      ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :archive, :stop]])
      entries = [{"harbour.jpg", {:stored, photo.key}}, {"notes.txt", "notes"}]

      assert {:ok, %Storehouse.File{key: "exports/1.zip", content_type: "application/zip"} = file} =
               Archive.store(entries, "exports/1.zip", adapter: Memory)

      {:ok, zip} = Storehouse.read(file.key, adapter: Memory)
      assert file.bytes == byte_size(zip)
      assert file.checksum == Base.encode64(:crypto.hash(:sha256, zip))
      assert unzipped(tested(zip))["harbour.jpg"] == File.read!(@harbour)

      assert_received {[:storehouse, :archive, :stop], ^ref, _measures,
                       %{entries: 2, bytes: bytes}}

      assert bytes == file.bytes
    end

    test "that expires", %{photo: photo} do
      {:ok, file} =
        Archive.store([{"a.jpg", {:stored, photo.key}}], "exports/2.zip",
          adapter: Memory,
          expires_in: 86_400
        )

      assert "expiring/1d/" <> _rest = file.key
      assert String.ends_with?(file.key, "/exports/2.zip")
    end

    test "split in archives of at most :max_bytes, each whole", %{photo: photo} do
      entries = for i <- 1..5, do: {"photo-#{i}.jpg", {:stored, photo.key}}

      assert {:ok, parts} =
               Archive.store(entries, "exports/all.zip", adapter: Memory, max_bytes: 80_000)

      assert Enum.map(parts, & &1.key) == [
               "exports/all-1.zip",
               "exports/all-2.zip",
               "exports/all-3.zip"
             ]

      names =
        for part <- parts do
          assert part.bytes <= 80_000
          {:ok, zip} = Storehouse.read(part.key, adapter: Memory)
          zip |> tested() |> unzipped() |> Map.keys()
        end

      assert names |> List.flatten() |> Enum.sort() == Enum.map(entries, &elem(&1, 0))

      assert Archive.store(entries, "exports/x.zip", adapter: Memory, max_bytes: 10_000) ==
               {:error, {:too_large, "photo-1.jpg"}}

      assert Archive.store([{"s", {:stream, []}}], "exports/x.zip",
               adapter: Memory,
               max_bytes: 10_000
             ) ==
               {:error, {:unknown_size, "s"}}
    end

    test "a stored file not the size it was stops it, and nothing is kept", %{small: small} do
      path = Path.join(System.tmp_dir!(), "archive-larger-#{System.unique_integer([:positive])}")
      {:ok, archive} = Archive.stream([{"small.png", {:stored, small.key}}], adapter: Memory)

      # Replaced, larger, between the plan and the making.
      File.write!(path, File.read!(@harbour))
      {:ok, _url} = Memory.put(small.key, path, %{content_type: "image/png"})

      assert_raise ArgumentError, ~r/small.png is larger than its 77 bytes/, fn ->
        Enum.to_list(archive)
      end

      # Smaller: cut short, not padded.
      {:ok, archive} = Archive.stream([{"small.png", {:stored, small.key}}], adapter: Memory)
      File.write!(path, "tiny")
      {:ok, _url} = Memory.put(small.key, path, %{content_type: "image/png"})
      File.rm(path)

      assert_raise ArgumentError, ~r/small.png is 4 bytes, not 35367/, fn ->
        Enum.to_list(archive)
      end
    end

    test "a stream's error leaves nothing" do
      broken =
        Stream.map([1, 2], fn
          2 -> raise Storehouse.ReadError, key: "k", reason: :gone
          n -> "#{n}"
        end)

      assert Archive.store([{"a.txt", {:stream, broken}}], "exports/broken.zip", adapter: Memory) ==
               {:error, :gone}

      assert Storehouse.head("exports/broken.zip", adapter: Memory) == {:error, :enoent}
    end
  end

  describe "store_later/3" do
    def ready(result, test), do: send(test, {:ready, result})
    def password, do: "from a function"

    test "made out of the request, then the app's function with it", %{photo: photo} do
      entries = [
        {"harbour.jpg", {:stored, photo.key}},
        {"made.json", {:call, {String, :duplicate, ["{}", 3]}}}
      ]

      # No runner's process here: it runs at once, as the runner would.
      assert :ok =
               Archive.store_later(entries, "exports/later.zip",
                 adapter: Memory,
                 password: {:call, {__MODULE__, :password, []}},
                 then: {__MODULE__, :ready, [self()]}
               )

      assert_received {:ready, {:ok, %Storehouse.File{key: "exports/later.zip"}}}
    end

    test "keeps only what a job can: never a password, a stream, or a large binary" do
      then = {__MODULE__, :ready, [self()]}

      assert_raise ArgumentError, ~r/never keeps a password/, fn ->
        Archive.store_later([{"a", "x"}], "e.zip", password: "plain", then: then)
      end

      assert_raise ArgumentError, ~r/a stream cannot be kept/, fn ->
        Archive.store_later([{"a", {:stream, []}}], "e.zip", then: then)
      end

      assert_raise ArgumentError, ~r/too large to keep/, fn ->
        Archive.store_later([{"a", :binary.copy("x", 2_000_000)}], "e.zip", then: then)
      end
    end
  end

  @tag :large
  @tag :tmp_dir
  @tag timeout: 900_000
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

    for compression <- [:none, :compress] do
      {:ok, zip} = Archive.stream(entries, adapter: Storehouse.Local, compression: compression)
      path = Path.join(dir, "big-#{compression}.zip")
      File.open!(path, [:write, :raw], fn io -> Enum.each(zip, &(:ok = :file.write(io, &1))) end)

      assert {output, 0} = System.cmd("unzip", ["-t", path], stderr_to_stdout: true)
      assert output =~ "No errors detected"
      File.rm!(path)
    end
  end
end
