defmodule Storehouse.Image.JPEGTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Storehouse.Image.JPEG

  @harbour File.read!(Path.expand("../../fixtures/harbour.jpg", __DIR__))
  @camera File.read!(Path.expand("../../fixtures/exif/camera.jpg", __DIR__))
  @phone File.read!(Path.expand("../../fixtures/exif/phone.jpg", __DIR__))

  @exif "Exif\0\0"
  @xmp "http://ns.adobe.com/xap/1.0/\0"

  # A JPEG's segments, as this test reads them on its own: `{marker,
  # payload}` up to the image data, and the rest.
  defp parse(<<0xFF, 0xD8, rest::binary>>), do: parse(rest, [])

  defp parse(<<0xFF, marker, _rest::binary>> = tail, acc) when marker in [0xDA, 0xD9],
    do: {Enum.reverse(acc), tail}

  defp parse(<<0xFF, marker, length::16, rest::binary>>, acc) do
    size = length - 2
    <<payload::binary-size(^size), next::binary>> = rest
    parse(next, [{marker, payload} | acc])
  end

  # What draws the image: every segment but metadata, and the image data.
  defp image(jpeg) do
    {segments, tail} = parse(jpeg)
    {Enum.reject(segments, fn {marker, _p} -> marker in 0xE0..0xEF or marker == 0xFE end), tail}
  end

  defp build(segments, tail) do
    IO.iodata_to_binary([
      <<0xFF, 0xD8>>,
      for({m, p} <- segments, do: <<0xFF, m, byte_size(p) + 2::16, p::binary>>),
      tail
    ])
  end

  # harbour.jpg's tables and image data, with these metadata segments.
  defp with_metadata(segments) do
    {image, tail} = image(@harbour)
    build(segments ++ image, tail)
  end

  defp exif_of(jpeg) do
    {segments, _tail} = parse(jpeg)
    List.first(for {0xE1, @exif <> tiff} <- segments, do: tiff)
  end

  # IFD0's tags: `{type, count, value field}` by tag.
  defp ifd0(nil), do: %{}

  defp ifd0(<<order::binary-2, _rest::binary>> = tiff) do
    endian = if order == "II", do: :little, else: :big
    at = u(binary_part(tiff, 4, 4), endian)
    count = u(binary_part(tiff, at, 2), endian)

    Map.new(0..(count - 1)//1, fn i ->
      <<tag::binary-2, type::binary-2, n::binary-4, value::binary-4>> =
        binary_part(tiff, at + 2 + i * 12, 12)

      {u(tag, endian), {u(type, endian), u(n, endian), value}}
    end)
  end

  defp u(bytes, :little), do: :binary.decode_unsigned(bytes, :little)
  defp u(bytes, :big), do: :binary.decode_unsigned(bytes, :big)

  # A TIFF of these IFD0 entries `{tag, type, count, bytes}`, with a GPS
  # directory when `gps`, in either byte order.
  defp tiff(endian, entries, gps) do
    gps_entries = [{0x0001, 2, 2, "N\0"}, {0x0012, 2, 15, "SECRET-DATUM-1\0"}]
    # Where the GPS directory goes: after IFD0, with its pointer, and its values.
    gps_at = 8 + byte_size(directory([{0x8825, 4, 1, <<0::32>>} | entries], 8, endian))
    ifd0 = if gps, do: [{0x8825, 4, 1, n(gps_at, 4, endian)} | entries], else: entries

    IO.iodata_to_binary([
      if(endian == :little, do: "II", else: "MM"),
      n(42, 2, endian),
      n(8, 4, endian),
      directory(ifd0, 8, endian),
      if(gps, do: directory(gps_entries, gps_at, endian), else: [])
    ])
  end

  defp directory(entries, at, endian) do
    entries = Enum.sort_by(entries, &elem(&1, 0))
    data_at = at + 6 + 12 * length(entries)

    {fields, data, _at} =
      Enum.reduce(entries, {[], [], data_at}, fn entry, {fields, data, pos} ->
        {field, value} = field(entry, pos, endian)
        {[field | fields], [value | data], pos + byte_size(value)}
      end)

    IO.iodata_to_binary([
      n(length(entries), 2, endian),
      Enum.reverse(fields),
      n(0, 4, endian),
      Enum.reverse(data)
    ])
  end

  defp field({tag, type, count, bytes}, pos, endian) do
    head = [n(tag, 2, endian), n(type, 2, endian), n(count, 4, endian)]

    if byte_size(bytes) <= 4,
      do: {[head, bytes <> :binary.copy(<<0>>, 4 - byte_size(bytes))], ""},
      else: {[head, n(pos, 4, endian)], bytes <> :binary.copy(<<0>>, rem(byte_size(bytes), 2))}
  end

  defp n(value, size, endian),
    do: value |> :binary.encode_unsigned(endian) |> pad_to(size, endian)

  defp pad_to(bytes, size, :big), do: :binary.copy(<<0>>, size - byte_size(bytes)) <> bytes
  defp pad_to(bytes, size, :little), do: bytes <> :binary.copy(<<0>>, size - byte_size(bytes))

  defp text(tag, value), do: {tag, 2, byte_size(value) + 1, value <> "\0"}

  describe "strip(:gps)" do
    test "removes where a camera's and a phone's photos were taken, and nothing else" do
      for jpeg <- [@camera, @phone] do
        assert Map.has_key?(ifd0(exif_of(jpeg)), 0x8825)
        assert {:ok, stripped} = JPEG.strip(jpeg, :gps)

        refute Map.has_key?(ifd0(exif_of(stripped)), 0x8825)
        assert image(stripped) == image(jpeg)
        assert {:ok, tags} = JPEG.tags(stripped)
        assert tags == elem(JPEG.tags(jpeg), 1)
        # In place: no byte moves, so a maker's notes keep their offsets.
        assert byte_size(exif_of(stripped)) == byte_size(exif_of(jpeg))
        assert :binary.match(stripped, "MAKERNOTE-blob") != :nomatch
      end
    end

    test "the GPS values are zeroed, not only unlinked, in either byte order" do
      for endian <- [:little, :big] do
        jpeg = with_metadata([{0xE1, @exif <> tiff(endian, [text(0x013B, "Ana Sousa")], true)}])
        assert :binary.match(jpeg, "SECRET-DATUM") != :nomatch

        {:ok, stripped} = JPEG.strip(jpeg, :gps)
        assert :binary.match(stripped, "SECRET-DATUM") == :nomatch
        assert {:ok, %{artist: "Ana Sousa"}} = JPEG.tags(stripped)
      end
    end

    test "removes the GPS properties of XMP, and keeps the rest" do
      {:ok, stripped} = JPEG.strip(@phone, :gps)
      {segments, _tail} = parse(stripped)
      [xml] = for {0xE1, @xmp <> xml} <- segments, do: xml

      refute xml =~ "GPS"
      assert xml =~ "<rdf:li>Someone</rdf:li>"
      assert xml =~ ~s(<rdf:Description rdf:about="")
    end

    test "a photo with no location is given back byte for byte" do
      assert JPEG.strip(@harbour, :gps) == {:ok, @harbour}
      {:ok, once} = JPEG.strip(@camera, :gps)
      assert JPEG.strip(once, :gps) == {:ok, once}
    end
  end

  describe "strip({:keep, tags})" do
    test "keeps only the tags named, and what draws the image" do
      {:ok, kept} = JPEG.strip(@phone, {:keep, [:orientation, :copyright, :iso]})

      assert JPEG.tags(kept) == {:ok, %{orientation: 6, copyright: "Old Copyright", iso: 200}}
      assert image(kept) == image(@phone)
      {segments, _tail} = parse(kept)

      assert Enum.map(segments, fn {m, p} -> {m, binary_part(p, 0, 4)} end)
             |> Enum.filter(fn {m, _p} -> m in 0xE0..0xEF end) ==
               [{0xE0, "JFIF"}, {0xE1, "Exif"}, {0xE2, "ICC_"}]

      refute kept =~ "MAKERNOTE"
      refute kept =~ "Someone"
    end

    test "with none of the tags, no Exif is left" do
      {:ok, kept} = JPEG.strip(@camera, {:keep, [:lens_model]})
      assert exif_of(kept) == nil
      assert image(kept) == image(@camera)
    end

    test "comments, IPTC and other apps' segments go" do
      jpeg =
        with_metadata([
          {0xE0, "JFIF\0" <> <<1, 2, 0, 0, 1, 0, 1, 0, 0>>},
          {0xED, "Photoshop 3.0\0" <> "IPTC: a city"},
          {0xEE, "Adobe" <> <<0, 100, 0, 0, 0, 0, 1>>},
          {0xEB, "an app's own"},
          {0xFE, "a comment"}
        ])

      {:ok, kept} = JPEG.strip(jpeg, {:keep, []})
      {segments, _tail} = parse(kept)
      assert for({m, _p} <- segments, m in 0xE0..0xFE, do: m) == [0xE0, 0xEE]
    end

    test "an MPF index keeps pointing at the pictures after the image" do
      # An MPF index of two pictures, the second after the image's end, at
      # an offset from the index, with an XMP segment between them.
      entries = <<0::32, 100::32, 0::32, 0::32>> <> <<0::32, 50::32, 9_000::32, 0::32>>
      ifd = <<1::16, 0xB002::16, 7::16, 32::32, 26::32, 0::32>>
      mpf = "MPF\0" <> <<"MM", 42::16, 8::32>> <> ifd <> entries
      xmp = {0xE1, @xmp <> String.duplicate("x", 300)}
      jpeg = with_metadata([{0xE2, mpf}, xmp])

      {:ok, kept} = JPEG.strip(jpeg, {:keep, []})
      {[{0xE2, "MPF\0" <> tiff} | _rest], _tail} = parse(kept)
      <<_head::binary-size(26), _first::binary-16, _a::32, _s::32, offset::32, _d::32>> = tiff

      # The XMP segment, its marker and length too, is gone from between.
      assert offset == 9_000 - (byte_size(@xmp) + 300 + 4)
    end

    test "a tag it does not know is refused" do
      assert_raise ArgumentError, ~r/no tag :gps_latitude/, fn ->
        JPEG.strip(@camera, {:keep, [:gps_latitude]})
      end
    end
  end

  describe "put_tags/2" do
    test "writes the author's name over the old one, which does not stay in the file" do
      for jpeg <- [@camera, @phone] do
        {:ok, put} = JPEG.put_tags(jpeg, %{artist: "Ana Sousa", copyright: "© Ana Sousa"})

        assert {:ok, %{artist: "Ana Sousa", copyright: "© Ana Sousa", orientation: 6} = tags} =
                 JPEG.tags(put)

        assert Map.delete(tags, :artist) |> Map.delete(:copyright) ==
                 elem(JPEG.tags(jpeg), 1) |> Map.delete(:artist) |> Map.delete(:copyright)

        assert image(put) == image(jpeg)
        assert :binary.match(put, "Old Name") == :nomatch
        assert :binary.match(put, "Old Copyright") == :nomatch
        assert :binary.match(put, "MAKERNOTE-blob") != :nomatch
        # The GPS directory is where it was.
        assert Map.has_key?(ifd0(exif_of(put)), 0x8825)
      end
    end

    test "nil removes a tag" do
      {:ok, put} = JPEG.put_tags(@camera, %{artist: nil})
      {:ok, tags} = JPEG.tags(put)
      refute Map.has_key?(tags, :artist)
      assert tags.copyright == "Old Copyright"
      assert :binary.match(put, "Old Name") == :nomatch
    end

    test "a photo with no Exif is given one, after its JFIF header" do
      {:ok, put} = JPEG.put_tags(@harbour, %{copyright: "© Ana"})
      assert JPEG.tags(put) == {:ok, %{copyright: "© Ana"}}
      assert image(put) == image(@harbour)
      {[{0xE0, "JFIF" <> _}, {0xE1, @exif <> _tiff} | _rest], _tail} = parse(put)

      assert JPEG.put_tags(@harbour, %{artist: nil}) == {:ok, @harbour}
    end

    test "written again and again, in either byte order" do
      jpeg = with_metadata([{0xE1, @exif <> tiff(:big, [{0x0112, 3, 1, <<0, 8>>}], false)}])

      final =
        Enum.reduce(1..5, jpeg, fn i, jpeg ->
          {:ok, jpeg} = JPEG.put_tags(jpeg, %{artist: "Name #{i}"})
          jpeg
        end)

      assert JPEG.tags(final) == {:ok, %{orientation: 8, artist: "Name 5"}}
      assert :binary.match(final, "Name 4") == :nomatch
    end

    test "refuses tags it does not write, text with a NUL, and an Exif past a segment's size" do
      assert_raise ArgumentError, fn -> JPEG.put_tags(@camera, %{orientation: 1}) end
      assert_raise ArgumentError, fn -> JPEG.put_tags(@camera, %{artist: "a\0b"}) end

      assert JPEG.put_tags(@camera, %{artist: String.duplicate("a", 70_000)}) ==
               {:error, :exif_too_large}
    end
  end

  describe "edit_file/3" do
    @tag :tmp_dir
    test "writes what edit/2 gives, reading only the metadata", %{tmp_dir: dir} do
      changes = [put: %{artist: "Ana"}, strip: :gps]

      for {name, jpeg} <- [camera: @camera, phone: @phone] do
        from = Path.join(dir, "#{name}.jpg")
        to = Path.join(dir, "#{name}-edited.jpg")
        File.write!(from, jpeg)

        assert JPEG.edit_file(from, to, changes) == :ok
        assert {:ok, File.read!(to)} == JPEG.edit(jpeg, changes)
        assert File.read!(from) == jpeg
      end
    end

    @tag :tmp_dir
    test "nothing to change, a file cut short, and no file", %{tmp_dir: dir} do
      from = Path.join(dir, "harbour.jpg")
      to = Path.join(dir, "out.jpg")
      File.write!(from, @harbour)

      assert JPEG.edit_file(from, to, strip: :gps) == :unchanged
      refute File.exists?(to)

      File.write!(from, binary_part(@camera, 0, 100))
      assert JPEG.edit_file(from, to, strip: :gps) == {:error, :malformed}
      assert JPEG.edit_file(Path.join(dir, "none.jpg"), to, strip: :gps) == {:error, :enoent}
    end
  end

  describe "what it refuses" do
    test "not a JPEG" do
      png = File.read!(Path.expand("../../fixtures/small.png", __DIR__))
      assert JPEG.strip(png, :gps) == {:error, :not_jpeg}
      assert JPEG.put_tags(png, %{artist: "Ana"}) == {:error, :not_jpeg}
      assert JPEG.tags(png) == {:error, :not_jpeg}
    end

    test "a segment cut short, and an Exif that cannot be read" do
      assert JPEG.strip(binary_part(@camera, 0, 100), :gps) == {:error, :malformed}

      broken = with_metadata([{0xE1, @exif <> "MM" <> <<42::16, 9_999::32>>}])
      assert JPEG.strip(broken, :gps) == {:error, :malformed_exif}
      assert JPEG.put_tags(broken, %{artist: "Ana"}) == {:error, :malformed_exif}
      assert JPEG.tags(broken) == {:error, :malformed_exif}
    end
  end

  # Generated layouts of metadata segments, before harbour.jpg's image.

  defp segment do
    one_of([
      constant({0xE0, "JFIF\0" <> <<1, 2, 0, 0, 1, 0, 1, 0, 0>>}),
      map(exif(), &{0xE1, @exif <> &1}),
      map(binary(), &{0xE2, "ICC_PROFILE\0" <> &1}),
      map(binary(), &{0xFE, &1}),
      map(tuple({integer(0xE3..0xEF), binary()}), & &1),
      map(boolean(), fn gps ->
        attribute = if gps, do: ~s( exif:GPSLatitude="41,8N"), else: ""

        {0xE1,
         @xmp <>
           ~s(<rdf:Description rdf:about=""#{attribute}><dc:title>t</dc:title></rdf:Description>)}
      end)
    ])
  end

  defp exif do
    gen all(
          endian <- member_of([:little, :big]),
          gps <- boolean(),
          artist <- string(:alphanumeric, max_length: 40),
          orientation <- integer(1..8)
        ) do
      entries = [
        {0x0112, 3, 1, :binary.encode_unsigned(orientation, endian) |> pad_to(2, endian)}
      ]

      entries = if artist == "", do: entries, else: [text(0x013B, artist) | entries]
      tiff(endian, entries, gps)
    end
  end

  property "editing never changes what draws the image, and strip(:gps) leaves no GPS" do
    check all(
            segments <- list_of(segment(), max_length: 6),
            name <- string(:printable, max_length: 30)
          ) do
      jpeg = with_metadata(segments)

      {:ok, stripped} = JPEG.strip(jpeg, :gps)
      assert image(stripped) == image(jpeg)
      refute stripped =~ "SECRET-DATUM"
      refute stripped =~ "exif:GPS"
      {stripped_segments, _tail} = parse(stripped)

      for {_m, @exif <> tiff} <- stripped_segments,
          do: refute(Map.has_key?(ifd0(tiff), 0x8825))

      {:ok, kept} = JPEG.strip(jpeg, {:keep, [:orientation]})
      assert image(kept) == image(jpeg)

      name = String.replace(name, "\0", "")
      {:ok, put} = JPEG.put_tags(stripped, %{artist: name})
      assert image(put) == image(jpeg)
      assert {:ok, %{artist: ^name}} = JPEG.tags(put)
    end
  end
end
