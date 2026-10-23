defmodule Storehouse.PlaceholderTest do
  use ExUnit.Case, async: true

  alias Storehouse.Analyzer.Placeholder
  alias Storehouse.Memory
  alias Vix.Vips.Image

  @fixtures Path.expand("../fixtures", __DIR__)
  @data_uri ~r/^data:image\/(webp|png|jpeg);base64,[A-Za-z0-9+\/=]+$/

  setup do
    Memory.checkout()
    :ok
  end

  defp placeholder(name, opts \\ []) do
    path = Path.join(@fixtures, name)
    {:ok, file} = Storehouse.store(path, adapter: Memory)
    {:ok, file} = Storehouse.analyze(file, [{Placeholder, opts}], adapter: Memory)
    file
  end

  defp decoded("data:" <> rest) do
    [_type, base64] = String.split(rest, ";base64,")
    {:ok, image} = Image.new_from_buffer(Base.decode64!(base64))
    image
  end

  for name <- ["harbour.jpg", "small.png", "small.webp"] do
    test "a few hundred bytes of #{name}, as large as it says" do
      result = Storehouse.File.analyzed(placeholder(unquote(name)), "placeholder")

      assert result["placeholder"] =~ @data_uri
      assert byte_size(result["placeholder"]) < 1_024
      assert result["color"] =~ ~r/^#[0-9a-f]{6}$/
      assert max(result["width"], result["height"]) == 16

      image = decoded(result["placeholder"])
      assert {Image.width(image), Image.height(image)} == {result["width"], result["height"]}
    end
  end

  test "the photograph's average colour" do
    assert %{"color" => "#9a7b76"} =
             Storehouse.File.analyzed(placeholder("harbour.jpg"), "placeholder")
  end

  test "turned as its EXIF says" do
    result = Storehouse.File.analyzed(placeholder("turned.jpg"), "placeholder")
    assert result["width"] < result["height"]
  end

  test "transparency laid on a background, when asked" do
    kept = Storehouse.File.analyzed(placeholder("exif/photo.png"), "placeholder")
    black = placeholder("exif/photo.png", background: "#000000")
    black = Storehouse.File.analyzed(black, "placeholder")

    assert kept["color"] != black["color"]
    assert Image.has_alpha?(decoded(kept["placeholder"]))
    refute Image.has_alpha?(decoded(black["placeholder"]))
  end

  test "in JPEG or PNG, and larger" do
    jpeg = placeholder("harbour.jpg", format: :jpeg)

    assert "data:image/jpeg;base64," <> _ =
             Storehouse.File.analyzed(jpeg, "placeholder")["placeholder"]

    png =
      Storehouse.File.analyzed(placeholder("harbour.jpg", format: :png, size: 32), "placeholder")

    assert "data:image/png;base64," <> _ = png["placeholder"]
    assert max(png["width"], png["height"]) == 32
  end

  test "none of the original's metadata, where it was taken least of all" do
    assert File.read!(Path.join(@fixtures, "exif/camera.jpg")) =~ "Exif"

    for format <- [:webp, :jpeg, :png] do
      result =
        Storehouse.File.analyzed(placeholder("exif/camera.jpg", format: format), "placeholder")

      "data:" <> rest = result["placeholder"]
      [_type, base64] = String.split(rest, ";base64,")
      bytes = Base.decode64!(base64)

      refute bytes =~ "Exif"
      refute bytes =~ "GPS"
      refute bytes =~ "ICC_PROFILE"
      refute bytes =~ "<x:xmpmeta"
    end
  end

  @tag :tmp_dir
  test "what is not an image is skipped", %{tmp_dir: dir} do
    path = Path.join(dir, "words.txt")
    File.write!(path, "Not a photograph.")

    {:ok, file} = Storehouse.store(path, adapter: Memory)
    {:ok, file} = Storehouse.analyze(file, [Placeholder], adapter: Memory)
    assert Storehouse.File.analysis(file, "placeholder").status == :skipped
  end

  @tag :tmp_dir
  test "an image libvips cannot read fails the step, with why", %{tmp_dir: dir} do
    # A JPEG's first bytes, and nothing of its picture.
    path = Path.join(dir, "cut.jpg")
    File.write!(path, binary_part(File.read!(Path.join(@fixtures, "harbour.jpg")), 0, 200))

    {:ok, file} = Storehouse.store(path, adapter: Memory)
    assert file.content_type == "image/jpeg"
    {:ok, file} = Storehouse.analyze(file, [Placeholder], adapter: Memory)
    analysis = Storehouse.File.analysis(file, "placeholder")

    assert analysis.status == :failed
    assert is_binary(analysis.error)
  end

  test "a background other than #rrggbb is refused" do
    file = placeholder("harbour.jpg", background: "black")
    assert Storehouse.File.analysis(file, "placeholder").error =~ "#rrggbb"
  end

  # What indie.camera keeps (`images.placeholder`, `images.color`) and the
  # checks its pages make before they paint one.
  test "16 pixels of WebP at quality 40, on black" do
    result =
      "harbour.jpg"
      |> placeholder(size: 16, quality: 40, background: "#000000")
      |> Storehouse.File.analyzed("placeholder")

    assert "data:image/webp;base64," <> _ = result["placeholder"]
    assert result["placeholder"] =~ @data_uri
    assert result["color"] =~ ~r/^#[0-9a-f]{6}$/
  end
end
