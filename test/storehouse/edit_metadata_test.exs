defmodule Storehouse.Analyzer.EditMetadataTest do
  use ExUnit.Case, async: true

  alias Storehouse.Analyzer.EditMetadata
  alias Storehouse.Memory
  alias StorehouseTest.Analyzers.Contents

  @camera Path.expand("../fixtures/exif/camera.jpg", __DIR__)
  @png Path.expand("../fixtures/small.png", __DIR__)

  setup do
    Memory.checkout()
    :ok
  end

  defp store(path, steps),
    do: Storehouse.store(path, adapter: Memory, analyze: steps)

  defp stored(file), do: Memory.get(file.key).body

  test "without the step, a stored photo's bytes and checksum are as uploaded" do
    {:ok, file} = store(@camera, [{Contents, test: self()}])

    assert stored(file) == File.read!(@camera)
    assert file.checksum == Base.encode64(:crypto.hash(:sha256, File.read!(@camera)))
  end

  test "strips the location from the stored original, and the steps after it read the edit" do
    original = File.read!(@camera)
    {:ok, file} = store(@camera, [{EditMetadata, strip: :gps}, {Contents, test: self()}])

    edited = stored(file)
    assert edited != original
    assert {:ok, ^edited} = Storehouse.JPEG.strip(original, :gps)
    assert_received {:contents, path, ^edited}
    refute File.exists?(path)

    # The file's checksum stays the upload's, which finds the same upload
    # again; the step has the stored one's.
    assert file.checksum == Base.encode64(:crypto.hash(:sha256, original))

    assert Storehouse.File.analyzed(file, :edit_metadata) == %{
             "changed" => true,
             "stripped" => "gps",
             "put" => [],
             "bytes" => byte_size(edited),
             "checksum" => Base.encode64(:crypto.hash(:sha256, edited))
           }
  end

  test "writes tags, after keeping only some, on a file already stored" do
    {:ok, file} = Storehouse.store(@camera, adapter: Memory)

    {:ok, file} =
      Storehouse.analyze(
        file,
        [{EditMetadata, strip: {:keep, [:orientation]}, put: %{artist: "Ana Sousa"}}],
        adapter: Memory
      )

    assert Storehouse.JPEG.tags(stored(file)) == {:ok, %{orientation: 6, artist: "Ana Sousa"}}

    assert %{"stripped" => %{"kept" => ["orientation"]}, "put" => ["artist"]} =
             Storehouse.File.analyzed(file, :edit_metadata)
  end

  test "nothing to change: the file is not written again" do
    {:ok, file} = Storehouse.store(@camera, adapter: Memory)
    {:ok, file} = Storehouse.analyze(file, [{EditMetadata, strip: :gps}], adapter: Memory)
    written = Memory.get(file.key)

    {:ok, again} =
      Storehouse.analyze(file, [{EditMetadata, strip: :gps}], adapter: Memory, force: true)

    assert Storehouse.File.analyzed(again, :edit_metadata) == %{"changed" => false}
    assert Memory.get(file.key) == written
  end

  test "skipped with nothing asked, and for a file that is not a JPEG" do
    {:ok, file} = store(@camera, [EditMetadata])
    assert %Storehouse.Analysis{status: :skipped} = Storehouse.File.analysis(file, :edit_metadata)
    assert stored(file) == File.read!(@camera)

    {:ok, png} = store(@png, [{EditMetadata, strip: :gps}])
    assert %Storehouse.Analysis{status: :skipped} = Storehouse.File.analysis(png, :edit_metadata)
    assert stored(png) == File.read!(@png)
  end

  defmodule Copy do
    @moduledoc false
    # An editor of the app's: it says it edited the file, and copies it.
    @behaviour Storehouse.MetadataEditor

    @impl true
    def edit(from, to, "image/png", changes) do
      send(self(), {:edit, changes})
      File.cp!(from, to)
      :ok
    end

    def edit(_from, _to, _type, _changes), do: :unsupported
  end

  test "another editor, as the step's: its types, and an edit that changed no byte" do
    {:ok, png} = store(@png, [{EditMetadata, strip: :gps, put: %{artist: "Ana"}, editor: Copy}])

    assert_received {:edit, [strip: :gps, put: %{artist: "Ana"}]}
    assert Storehouse.File.analyzed(png, :edit_metadata) == %{"changed" => false}
    assert stored(png) == File.read!(@png)

    {:ok, jpeg} = store(@camera, [{EditMetadata, strip: :gps, editor: Copy}])
    assert %Storehouse.Analysis{status: :skipped} = Storehouse.File.analysis(jpeg, :edit_metadata)
  end

  test "a JPEG it cannot read fails the step, and is left as it was" do
    broken = Path.join(System.tmp_dir!(), "broken-#{System.unique_integer([:positive])}.jpg")
    jpeg = File.read!(@camera)
    File.write!(broken, binary_part(jpeg, 0, 2) <> <<0xFF, 0xE1, 0x01, 0x00>> <> "Exif\0\0MM")
    on_exit(fn -> File.rm(broken) end)

    {:ok, file} = Storehouse.store(@camera, adapter: Memory)
    Memory.put(file.key, broken, %{content_type: "image/jpeg"})
    {:ok, file} = Storehouse.analyze(file, [{EditMetadata, strip: :gps}], adapter: Memory)

    assert %Storehouse.Analysis{status: :failed, error: ":malformed"} =
             Storehouse.File.analysis(file, :edit_metadata)

    assert stored(file) == File.read!(broken)
  end
end

defmodule Storehouse.Analyzer.EditMetadataConfigTest do
  # The app's config is the whole node's.
  use ExUnit.Case, async: false

  test "the editor of every step, in config" do
    Application.put_env(:storehouse, :metadata_editor, Storehouse.Analyzer.EditMetadataTest.Copy)
    on_exit(fn -> Application.delete_env(:storehouse, :metadata_editor) end)
    Storehouse.Memory.checkout()

    png = Path.expand("../fixtures/small.png", __DIR__)
    analyze = [{Storehouse.Analyzer.EditMetadata, strip: :gps}]
    {:ok, _file} = Storehouse.store(png, adapter: Storehouse.Memory, analyze: analyze)
    assert_received {:edit, [strip: :gps]}

    assert Storehouse.MetadataEditor.editor(editor: MyEditor) == MyEditor
  end
end
