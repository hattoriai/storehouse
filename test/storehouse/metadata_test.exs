defmodule Storehouse.MetadataTest do
  use ExUnit.Case, async: true

  alias Storehouse.Metadata

  doctest Storehouse.Metadata
  doctest Storehouse.File
  doctest Storehouse.Analysis

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
    test "the app's metadata merges, every key its own" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{credit: %{name: "Ana", year: 2025}})
      {:ok, file} = Storehouse.File.put_metadata(file, %{credit: %{year: 2026}, caption: "Quay"})

      assert file.metadata == %{
               "credit" => %{"name" => "Ana", "year" => 2026},
               "caption" => "Quay"
             }

      # No key is Storehouse's: analysis is the file's :analysis.
      {:ok, file} = Storehouse.File.put_metadata(file, %{"analyzed" => %{"by" => "hand"}})
      assert file.metadata["analyzed"] == %{"by" => "hand"}
      assert file.analysis == %{}
    end

    test "each step's analysis is its own, and leaves the metadata" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{caption: "Quay"})

      file =
        Storehouse.File.put_analysis(file, "exif", Storehouse.Analysis.ok(%{"camera" => "X100"}))

      file =
        Storehouse.File.put_analysis(file, "ocr", Storehouse.Analysis.ok(%{"error" => "blurred"}))

      file = Storehouse.File.put_analysis(file, "pages", Storehouse.Analysis.failed(:no_tool))

      file =
        Storehouse.File.put_analysis(file, "exif", Storehouse.Analysis.ok(%{"camera" => "X100V"}))

      assert Storehouse.File.analyzed(file, :exif) == %{"camera" => "X100V"}
      # A step's own "error" key is its result, not a failure.
      assert Storehouse.File.analyzed(file, "ocr") == %{"error" => "blurred"}
      assert Storehouse.File.analyzed(file, :pages) == nil

      assert %Storehouse.Analysis{status: :failed, error: ":no_tool"} =
               Storehouse.File.analysis(file, :pages)

      assert Storehouse.File.analysis(file, :missing) == nil
      assert file.metadata == %{"caption" => "Quay"}
    end

    test "an analysis as a map, and back" do
      analysis = Storehouse.Analysis.ok(%{"pages" => 12})

      assert analysis |> Storehouse.Analysis.to_map() |> Storehouse.Analysis.from_map() ==
               analysis

      failed = Storehouse.Analysis.failed("the tool crashed")
      assert failed |> Storehouse.Analysis.to_map() |> Storehouse.Analysis.from_map() == failed

      assert Storehouse.Analysis.from_map(%{"status" => "done", "at" => "2026-10-23T08:00:00Z"}) ==
               nil

      assert Storehouse.Analysis.from_map(%{"status" => "ok", "at" => "yesterday"}) == nil
    end

    test "as JSON, without the analysis unless asked" do
      {:ok, file} = Storehouse.File.put_metadata(file(), %{caption: "Quay"})

      file =
        Storehouse.File.put_analysis(
          file,
          "exif",
          Storehouse.Analysis.ok(%{"gps" => [38.7, -9.1]})
        )

      file =
        Storehouse.File.put_analysis(
          file,
          "colors",
          Storehouse.Analysis.ok(%{"main" => "#2a2722"})
        )

      # Elixir's JSON (1.18 and later), and Jason.
      for library <- Enum.filter([JSON, Jason], &Code.ensure_loaded?/1),
          json = library.encode!(file) do
        decoded = Jason.decode!(json)
        assert decoded["url"] == "/uploads/2026/10/a.jpg"
        assert decoded["metadata"] == %{"caption" => "Quay"}
        refute Map.has_key?(decoded, "analysis")
        refute json =~ "gps"
      end

      assert %{"colors" => %{"status" => "ok", "result" => %{"main" => "#2a2722"}}} =
               Storehouse.File.to_map(file, analysis: [:colors])["analysis"]

      refute Map.has_key?(Storehouse.File.to_map(file, analysis: [:colors])["analysis"], "exif")
      assert Storehouse.File.to_map(file, analysis: true)["analysis"]["exif"]
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
