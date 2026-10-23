defmodule Storehouse.Image.ExifTest do
  # The edits of a file's metadata, whatever the file is made of: their
  # work grows with the file, never with the file times its entries.
  use ExUnit.Case, async: true

  alias Storehouse.Image.Exif

  # What the regular expressions of before took out of XMP, on XMP that
  # makes them no trouble.
  @attribute ~r/\s+exif:GPS\w*\s*=\s*("[^"]*"|'[^']*')/
  @element ~r{<exif:(GPS\w*)\b[^>]*?(/>|>.*?</exif:\1\s*>)}s
  defp before(xml), do: xml |> String.replace(@attribute, "") |> String.replace(@element, "")

  defp timed(fun) do
    {micros, _result} = :timer.tc(fun)
    micros
  end

  describe "xmp_without_gps/1" do
    test "takes out what it took out before" do
      for xml <- [
            ~s(<rdf:Description exif:GPSLatitude="41,9.1N" exif:GPSLongitude='8,37.2W' tiff:Make="X"/>),
            ~s(<x><exif:GPSAltitude>12/1</exif:GPSAltitude><tiff:Model>Y</tiff:Model></x>),
            ~s(<exif:GPSTimeStamp/><a/>),
            ~s(<exif:GPSAreaInformation><rdf:Alt><rdf:li xml:lang="x-default">Porto</rdf:li></rdf:Alt></exif:GPSAreaInformation>),
            ~s(<exif:GPSVersionID>\n  <rdf:Seq><rdf:li>2</rdf:li></rdf:Seq>\n</exif:GPSVersionID> <b exif:GPSMapDatum = "WGS-84"/>),
            ~s(<a exif:DateTimeOriginal="2026"/>),
            "no GPS at all"
          ] do
        assert Exif.xmp_without_gps(xml) == before(xml), xml
      end
    end

    test "in time that grows with the text, not with its tags times it" do
      for unit <- [
            "<exif:GPSa>",
            "<exif:GPSa ",
            ~s( exif:GPSa="),
            String.duplicate(" ", 9) <> "x"
          ] do
        small = timed(fn -> Exif.xmp_without_gps(String.duplicate(unit, 4_000)) end)
        large = timed(fn -> Exif.xmp_without_gps(String.duplicate(unit, 32_000)) end)

        # Eight times the text: about eight times the work, not sixty-four.
        assert large < 24 * max(small, 1_000), "#{inspect(unit)}: #{small} µs, then #{large} µs"
      end
    end
  end

  # A little-endian TIFF of these IFD0 entries, then `pad` bytes.
  defp tiff(entries, pad) do
    fields =
      for {tag, type, count, value} <- entries,
          do: <<tag::little-16, type::little-16, count::little-32, value::little-32>>

    ifd = <<length(entries)::little-16>> <> IO.iodata_to_binary(fields) <> <<0::32>>
    <<"II", 42::little-16, 8::little-32>> <> ifd <> :binary.copy(<<0>>, pad)
  end

  test "values kept are copied once each, never more than the TIFF has" do
    # A thousand copyright entries, each the whole TIFF.
    size = 8 + 6 + 12 * 1_000 + 4_000
    aliased = tiff(for(_ <- 1..1_000, do: {0x8298, 1, size, 0}), 4_000)
    assert byte_size(aliased) == size

    kept = Exif.kept(aliased, {[0x8298], []})
    assert byte_size(kept) < 2 * size
  end

  test "a GPS strip and a put rebuild the TIFF once, however many entries it has" do
    for n <- [1_000, 4_000] do
      # Every entry a GPS pointer to the same directory, and a text tag.
      gps = tiff(for(_ <- 1..n, do: {0x8825, 4, 1, 8}), 200_000)
      texts = tiff(for(_ <- 1..n, do: {0x013B, 2, 8, 16}), 200_000)

      time =
        timed(fn -> Exif.without_gps(gps) end) + timed(fn -> Exif.put(texts, %{artist: "x"}) end)

      send(self(), {n, time})
    end

    assert_received {1_000, small}
    assert_received {4_000, large}
    # Four times the entries: not four times the TIFF copied four times.
    assert large < 8 * max(small, 1_000), "#{small} µs, then #{large} µs"
  end
end
