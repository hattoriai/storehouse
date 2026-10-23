defmodule Storehouse.HashesTest do
  use ExUnit.Case, async: true

  alias Storehouse.Analyzer
  alias Storehouse.Memory

  doctest Storehouse.ThumbHash
  doctest Storehouse.BlurHash

  @fixtures Path.expand("../fixtures", __DIR__)
  # Photographs' pixels, and the hashes the reference implementations make
  # of them.
  @references @fixtures |> Path.join("hashes.json") |> File.read!() |> Storehouse.JSON.decode!()

  setup do
    Memory.checkout()
    :ok
  end

  defp analyzed(name, step) do
    {:ok, file} = Storehouse.store(Path.join(@fixtures, name), adapter: Memory)
    {:ok, file} = Storehouse.analyze(file, [step], adapter: Memory)
    file
  end

  describe "encoders" do
    for image <- @references["images"] do
      test "the reference's ThumbHash and BlurHash of #{image["name"]}" do
        image = unquote(Macro.escape(image))
        rgba = Base.decode64!(image["rgba"])
        rgb = Base.decode64!(image["rgb"])

        assert Base.encode64(Storehouse.ThumbHash.encode(image["w"], image["h"], rgba)) ==
                 image["thumbhash"]

        assert Storehouse.BlurHash.encode(image["w"], image["h"], rgb, 4, 3) == image["blurhash"]
      end
    end

    test "a ThumbHash of at most 100 pixels a side" do
      assert_raise FunctionClauseError, fn ->
        Storehouse.ThumbHash.encode(101, 1, :binary.copy(<<0, 0, 0, 255>>, 101))
      end
    end

    test "a BlurHash as long as its components" do
      rgb = :binary.copy(<<10, 200, 30>>, 16)

      for {x, y} <- [{1, 1}, {4, 3}, {9, 9}] do
        assert byte_size(Storehouse.BlurHash.encode(4, 4, rgb, x, y)) == 6 + 2 * (x * y - 1)
      end
    end
  end

  describe "Storehouse.Analyzer.ThumbHash" do
    test "a photograph's, its colour and proportions" do
      result =
        "harbour.jpg" |> analyzed(Analyzer.ThumbHash) |> Storehouse.File.analyzed(:thumbhash)

      assert %{"color" => "#9a7b76", "width" => 100, "height" => 67} = result
      assert byte_size(Base.decode64!(result["thumbhash"])) in 20..30
    end

    test "transparency kept, unless laid on a background" do
      kept =
        "exif/photo.png" |> analyzed(Analyzer.ThumbHash) |> Storehouse.File.analyzed(:thumbhash)

      flat = analyzed("exif/photo.png", {Analyzer.ThumbHash, background: "#000000"})
      flat = Storehouse.File.analyzed(flat, :thumbhash)

      assert alpha?(kept["thumbhash"])
      refute alpha?(flat["thumbhash"])
    end

    # The header's 24th bit.
    defp alpha?(hash) do
      <<_::binary-2, flag::1, _::7, _::binary>> = Base.decode64!(hash)
      flag == 1
    end
  end

  describe "Storehouse.Analyzer.BlurHash" do
    test "a photograph's, its colour and proportions" do
      result = "harbour.jpg" |> analyzed(Analyzer.BlurHash) |> Storehouse.File.analyzed(:blurhash)

      assert %{"color" => "#9a7b76", "width" => 32, "height" => 21} = result
      assert byte_size(result["blurhash"]) == 28
    end

    test "with more components, from more pixels" do
      result =
        "harbour.jpg"
        |> analyzed({Analyzer.BlurHash, components: {9, 9}, size: 64})
        |> Storehouse.File.analyzed(:blurhash)

      assert byte_size(result["blurhash"]) == 6 + 2 * 80
      assert result["width"] == 64
    end
  end

  @tag :tmp_dir
  test "what is not an image is skipped, an image libvips cannot read fails", %{tmp_dir: dir} do
    words = Path.join(dir, "words.txt")
    File.write!(words, "Not a photograph.")
    cut = Path.join(dir, "cut.jpg")
    File.write!(cut, binary_part(File.read!(Path.join(@fixtures, "harbour.jpg")), 0, 200))

    for step <- [Analyzer.ThumbHash, Analyzer.BlurHash] do
      {:ok, file} = Storehouse.store(words, adapter: Memory)
      {:ok, file} = Storehouse.analyze(file, [step], adapter: Memory)
      assert Storehouse.File.analysis(file, step.name()).status == :skipped

      {:ok, file} = Storehouse.store(cut, adapter: Memory)
      {:ok, file} = Storehouse.analyze(file, [step], adapter: Memory)
      assert Storehouse.File.analysis(file, step.name()).status == :failed
    end
  end
end
