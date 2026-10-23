defmodule Storehouse.MetadataTest do
  use ExUnit.Case, async: true

  alias Storehouse.Metadata

  doctest Storehouse.Metadata
  doctest Storehouse.File

  @fixtures Path.expand("../fixtures", __DIR__)

  defp file(metadata \\ %{}),
    do: %Storehouse.File{
      key: "2026/10/a.jpg",
      url: "/uploads/2026/10/a.jpg",
      name: "a.jpg",
      content_type: "image/jpeg",
      bytes: 10,
      metadata: metadata
    }

  describe "normalize/1" do
    test "keeps what JSON holds, with string keys" do
      assert Metadata.normalize(%{
               "caption" => "Quay, at dusk",
               rating: 4.5,
               tags: ["harbour", %{kind: :boat}],
               hidden: false,
               note: nil,
               at: ~U[2026-10-23 08:00:00Z]
             }) ==
               {:ok,
                %{
                  "caption" => "Quay, at dusk",
                  "rating" => 4.5,
                  "tags" => ["harbour", %{"kind" => "boat"}],
                  "hidden" => false,
                  "note" => nil,
                  "at" => "2026-10-23T08:00:00Z"
                }}
    end

    test "refuses what JSON or jsonb cannot hold, with where it is" do
      for {metadata, path} <- [
            {%{"a" => {1, 2}}, ["a"]},
            {%{"a" => [1, self()]}, ["a", 1]},
            {%{"a" => <<0xFF>>}, ["a"]},
            {%{"a" => "nul\0"}, ["a"]},
            {%{"" => 1}, [""]},
            {%{1 => "one"}, ["1"]},
            {%{"a" => %URI{}}, ["a"]}
          ] do
        assert Metadata.normalize(metadata) == {:error, {:invalid_metadata, path}}
      end

      assert Metadata.normalize([1]) == {:error, {:invalid_metadata, []}}
    end

    test "refuses metadata too deep or too large" do
      deep = Enum.reduce(1..10, "bottom", &%{"level#{&1}" => &2})
      assert {:error, {:invalid_metadata, _path}} = Metadata.normalize(deep)

      assert Metadata.normalize(%{"text" => String.duplicate("a", 70_000)}) ==
               {:error, {:invalid_metadata, []}}
    end
  end

  describe "Storehouse.File" do
    test "the app's metadata merges, and never writes the analysis's" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{credit: %{name: "Ana", year: 2025}})
      {:ok, file} = Storehouse.File.put_metadata(file, %{credit: %{year: 2026}, caption: "Quay"})

      assert file.metadata == %{
               "credit" => %{"name" => "Ana", "year" => 2026},
               "caption" => "Quay"
             }

      assert Storehouse.File.put_metadata(file, %{"analyzed" => %{}}) ==
               {:error, {:invalid_metadata, ["analyzed"]}}
    end

    test "each analysis step replaces its own part, and leaves the app's" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{caption: "Quay"})

      {:ok, file} =
        Storehouse.File.put_analyzed(file, :exif, %{camera: "X100", gps: [38.7, -9.1]})

      {:ok, file} = Storehouse.File.put_analyzed(file, :placeholder, %{color: "#2a2722"})
      {:ok, file} = Storehouse.File.put_analyzed(file, :exif, %{camera: "X100V"})

      assert Storehouse.File.analyzed(file, :exif) == %{"camera" => "X100V"}
      assert Storehouse.File.analyzed(file, "placeholder") == %{"color" => "#2a2722"}
      assert Storehouse.File.analyzed(file, :missing) == nil
      assert file.metadata["caption"] == "Quay"

      assert Storehouse.File.put_analyzed(file, :exif, %{bad: {1}}) ==
               {:error, {:invalid_metadata, ["analyzed", "exif", "bad"]}}
    end

    test "as JSON, without the analysis's unless asked" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{caption: "Quay"})
      {:ok, file} = Storehouse.File.put_analyzed(file, :exif, %{gps: [38.7, -9.1]})
      {:ok, file} = Storehouse.File.put_analyzed(file, :placeholder, %{color: "#2a2722"})

      # Elixir's JSON (1.18 and later), and Jason.
      libraries = Enum.filter([JSON, Jason], &Code.ensure_loaded?/1)

      for library <- libraries, json = library.encode!(file) do
        decoded = Storehouse.JSON.decode!(json)
        assert decoded["url"] == "/uploads/2026/10/a.jpg"
        assert decoded["metadata"] == %{"caption" => "Quay"}
        refute json =~ "gps"
      end

      assert Storehouse.File.to_map(file, analyzed: [:placeholder])["metadata"] == %{
               "caption" => "Quay",
               "analyzed" => %{"placeholder" => %{"color" => "#2a2722"}}
             }

      assert Storehouse.File.to_map(file, analyzed: true)["metadata"]["analyzed"]["exif"]
      assert Storehouse.File.to_map(file, only: [:key, :nope]) == %{"key" => "2026/10/a.jpg"}
    end
  end

  describe "store/2 and verify_upload/2" do
    setup do
      Storehouse.Memory.checkout()
    end

    test "store/2 gives the file its metadata, or refuses it and stores nothing" do
      path = Path.join(@fixtures, "harbour.jpg")

      assert {:ok, file} =
               Storehouse.store(path, adapter: Storehouse.Memory, metadata: %{caption: "Quay"})

      assert file.metadata == %{"caption" => "Quay"}
      {:ok, plain} = Storehouse.store(path, adapter: Storehouse.Memory)
      assert plain.metadata == %{}

      before = Storehouse.Memory.keys()

      assert Storehouse.store(path, adapter: Storehouse.Memory, metadata: %{bad: {1}}) ==
               {:error, {:invalid_metadata, ["bad"]}}

      assert Storehouse.store(path, adapter: Storehouse.Memory, metadata: %{analyzed: %{}}) ==
               {:error, {:invalid_metadata, ["analyzed"]}}

      assert Storehouse.Memory.keys() == before
    end

    test "verify_upload/2 gives the file its metadata" do
      body = File.read!(Path.join(@fixtures, "harbour.jpg"))

      {:ok, upload} =
        Storehouse.presign_upload("harbour.jpg", "image/jpeg", byte_size(body),
          adapter: Storehouse.Memory
        )

      200 = Storehouse.Memory.put_upload(upload, body)

      assert {:ok, file} =
               Storehouse.verify_upload(upload.key,
                 adapter: Storehouse.Memory,
                 metadata: %{alt: "A quay at dusk"}
               )

      assert file.metadata == %{"alt" => "A quay at dusk"}
    end
  end
end
