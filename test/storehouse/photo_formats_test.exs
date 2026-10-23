defmodule Storehouse.PhotoFormatsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Storehouse.Check

  @fixtures Path.expand("../fixtures", __DIR__)

  defp fixture(name, claim \\ nil, opts \\ []),
    do: Check.describe(Path.join(@fixtures, name), claim, opts)

  defp describe_head(head), do: Check.describe_head(head, byte_size(head))

  test "the images of phones and cameras, with their sizes" do
    for {name, type, width, height} <- [
          {"small.heic", "image/heic", 64, 48},
          {"small.avif", "image/avif", 64, 48},
          {"small-le.tiff", "image/tiff", 64, 48},
          {"small-be16.tiff", "image/tiff", 40, 30},
          {"turned.tiff", "image/tiff", 48, 64},
          {"small.dng", "image/x-adobe-dng", 64, 48}
        ] do
      assert {:ok, %{content_type: ^type, width: ^width, height: ^height}} = fixture(name),
             name
    end
  end

  test "whatever the browser claims" do
    assert {:ok, %{content_type: "image/heic"}} =
             fixture("small.heic", "application/octet-stream")

    assert {:ok, %{content_type: "image/tiff"}} = fixture("small-le.tiff", "text/html")
  end

  test "the limits apply to them" do
    assert fixture("small.avif", nil, max_pixels: 64 * 48 - 1) == {:error, :too_large}
    assert {:ok, _description} = fixture("small.avif", nil, max_pixels: 64 * 48)
  end

  test "types, extensions and how they are served" do
    assert "image/heic" in Check.photos()
    refute "image/heic" in Check.images()
    refute "image/x-adobe-dng" in Check.photos()

    assert Check.extension("image/tiff") == ".tiff"
    assert Check.content_type(".TIF") == "image/tiff"
    assert Check.content_type(".heic") == "image/heic"
    assert Check.inline?("image/avif")
    refute Check.inline?("image/x-adobe-dng")
  end

  # A HEIF file of one item, put together box by box.
  defp box(type, body), do: <<8 + byte_size(body)::32, type::binary, body::binary>>

  defp heif(properties, ipma, opts \\ []) do
    ftyp = box("ftyp", Keyword.get(opts, :major, "mif1") <> <<0::32>> <> "mif1heic")
    pitm = box("pitm", <<0, 0::24, Keyword.get(opts, :primary, 1)::16>>)
    ipco = box("ipco", Enum.join(properties))
    iprp = box("iprp", ipco <> box("ipma", ipma))

    ftyp <>
      box("meta", <<0::32>> <> box("hdlr", <<0::32, 0::32, "pict", 0::96, 0>>) <> pitm <> iprp)
  end

  defp ispe(w, h), do: box("ispe", <<0::32, w::32, h::32>>)
  defp irot(angle), do: box("irot", <<0::6, angle::2>>)

  test "a HEIF image turned by its irot, and the primary item's size of many" do
    ipma = <<0, 0::24, 1::32, 1::16, 2, 1::1, 1::7, 0::1, 2::7>>

    assert {:ok, %{content_type: "image/heic", width: 3024, height: 4032}} =
             describe_head(heif([ispe(4032, 3024), irot(1)], ipma))

    # Two items: a thumbnail (1) and the photo (2), primary.
    ipma =
      <<0, 0::24, 2::32, 1::16, 1, 1::1, 1::7, 2::16, 2, 1::1, 2::7, 0::1, 3::7>>

    head = heif([ispe(320, 240), ispe(4032, 3024), irot(2)], ipma, primary: 2)
    assert {:ok, %{width: 4032, height: 3024}} = describe_head(head)
  end

  test "ipma with 32-bit item ids and 15-bit indexes" do
    ipma = <<1, 1::24, 1::32, 1::32, 1, 1::1, 1::15>>
    assert {:ok, %{width: 800, height: 600}} = describe_head(heif([ispe(800, 600)], ipma))
  end

  test "a HEIF image whose size the head does not hold has none" do
    ipma = <<0, 0::24, 1::32, 9::16, 1, 1::1, 1::7>>

    assert {:ok, %{content_type: "image/heic", width: nil, height: nil}} =
             describe_head(heif([ispe(800, 600)], ipma))
  end

  test "a Canon raw is not taken for a TIFF" do
    assert {:ok, %{content_type: "application/octet-stream"}} =
             describe_head(<<"II", 42::little-16, 16::little-32, "CR", 2, 0, 0::64>>)
  end

  property "any bytes after an image's signature are refused or read, never a crash" do
    check all(
            signature <-
              member_of([
                "II*\0",
                "MM\0*",
                <<0, 0, 0, 24, "ftypheic", 0::32, "mif1heic">>,
                <<0, 0, 0, 24, "ftypavif", 0::32, "mif1avif">>
              ]),
            rest <- binary(max_length: 512),
            max_runs: 2_000
          ) do
      head = signature <> rest
      assert {:ok, %{content_type: type}} = describe_head(head)
      assert is_binary(type)
    end
  end
end
