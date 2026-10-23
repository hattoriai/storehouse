defmodule Storehouse.PNGWebPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Storehouse.{JPEG, PNG, WebP}

  @fixtures Path.expand("../fixtures/exif", __DIR__)
  @png File.read!(Path.join(@fixtures, "photo.png"))
  @apng File.read!(Path.join(@fixtures, "animated.png"))
  @webp File.read!(Path.join(@fixtures, "photo.webp"))
  @simple File.read!(Path.join(@fixtures, "simple.webp"))
  @animated File.read!(Path.join(@fixtures, "animated.webp"))

  @changes [
    [strip: :gps],
    [strip: {:keep, [:orientation, :copyright]}],
    [put: %{artist: "Ana Sousa", copyright: "© Ana"}],
    [strip: :gps, put: %{artist: "Ana"}]
  ]

  # A PNG's chunks, as this test reads them on its own: `{type, data}`.
  defp png_chunks(<<0x89, "PNG\r\n", 0x1A, "\n", rest::binary>>), do: png_chunks(rest)
  defp png_chunks(""), do: []

  defp png_chunks(<<size::32, type::binary-4, data::binary-size(size), crc::32, rest::binary>>) do
    assert crc == :erlang.crc32([type, data]), "a #{type} chunk's checksum is wrong"
    [{type, data} | png_chunks(rest)]
  end

  # The text of a PNG's text chunks, inflated, all together.
  defp png_text(png) do
    for {type, data} <- png_chunks(png), type in ~w(tEXt zTXt iTXt), into: "" do
      [_keyword, rest] = :binary.split(data, <<0>>)

      case {type, rest} do
        {"tEXt", text} ->
          text

        {"zTXt", <<0, z::binary>>} ->
          :zlib.uncompress(z)

        {"iTXt", <<flag, 0, rest::binary>>} ->
          itxt(flag, rest)
      end
    end
  end

  # An iTXt's language and translated keyword, then its text.
  defp itxt(flag, rest) do
    [_language, rest] = :binary.split(rest, <<0>>)
    [_translated, text] = :binary.split(rest, <<0>>)
    if flag == 1, do: :zlib.uncompress(text), else: text
  end

  # What draws a PNG: every chunk but metadata.
  defp png_image(png),
    do: Enum.reject(png_chunks(png), fn {type, _d} -> type in ~w(eXIf tEXt zTXt iTXt tIME) end)

  # A WebP's chunks, checking the RIFF size.
  defp webp_chunks(<<"RIFF", size::little-32, "WEBP", rest::binary>>) do
    assert size == byte_size(rest) + 4
    webp_chunks(rest)
  end

  defp webp_chunks(""), do: []

  defp webp_chunks(<<fourcc::binary-4, size::little-32, data::binary-size(size), rest::binary>>) do
    pad = rem(size, 2)
    <<_pad::binary-size(^pad), rest::binary>> = rest
    [{fourcc, data} | webp_chunks(rest)]
  end

  defp webp_image(webp),
    do: Enum.reject(webp_chunks(webp), fn {fourcc, _d} -> fourcc in ["VP8X", "EXIF", "XMP "] end)

  defp gps?(file), do: file =~ "exif:GPS" or has_gps_directory?(file)

  # The Exif's IFD0 has a GPS entry (0x8825), in either byte order.
  defp has_gps_directory?(file) do
    :binary.match(file, <<0x25, 0x88, 4, 0>>) != :nomatch or
      :binary.match(file, <<0x88, 0x25, 0, 4>>) != :nomatch
  end

  describe "PNG" do
    test "every change leaves the image's chunks byte for byte, an APNG's frames too" do
      for png <- [@png, @apng], changes <- @changes do
        {:ok, edited} = PNG.edit(png, changes)
        assert png_image(edited) == png_image(png)
      end
    end

    test "strip(:gps) removes the location from Exif and XMP, and keeps the rest" do
      assert has_gps_directory?(@png) and png_text(@png) =~ "exif:GPS"
      {:ok, stripped} = PNG.edit(@png, strip: :gps)

      refute has_gps_directory?(stripped)
      refute png_text(stripped) =~ "GPS"
      assert png_text(stripped) =~ "Someone"
      assert PNG.tags(stripped) == PNG.tags(@png)
      assert PNG.edit(stripped, strip: :gps) == {:ok, stripped}
    end

    test "keeps only the tags named, and no other text" do
      {:ok, kept} = PNG.edit(@png, strip: {:keep, [:orientation, :copyright]})

      assert PNG.tags(kept) == {:ok, %{orientation: 1, copyright: "Old Copyright"}}
      types = Enum.map(png_chunks(kept), &elem(&1, 0))
      assert "iCCP" in types
      refute Enum.any?(types, &(&1 in ~w(tEXt zTXt iTXt)))
    end

    test "writes Exif and the text chunks readers show, in place of the old ones" do
      {:ok, put} = PNG.edit(@png, put: %{artist: "Ana Sousa", copyright: "© Ana"})

      assert {:ok, %{artist: "Ana Sousa", copyright: "© Ana"}} = PNG.tags(put)
      refute put =~ "Old Name"
      assert for({"iTXt", "Author\0" <> _} = c <- png_chunks(put), do: c) |> length() == 1

      # Before the image data, as Exif must be.
      types = Enum.map(png_chunks(put), &elem(&1, 0))
      assert Enum.find_index(types, &(&1 == "eXIf")) < Enum.find_index(types, &(&1 == "IDAT"))

      {:ok, plain} =
        PNG.edit(File.read!(Path.expand("../fixtures/small.png", __DIR__)), put: %{artist: "Ana"})

      assert PNG.tags(plain) == {:ok, %{artist: "Ana"}}
    end

    test "refuses what is not a PNG, chunks cut short, and text that inflates too far" do
      assert PNG.edit(@webp, strip: :gps) == {:error, :not_png}
      assert PNG.edit(binary_part(@png, 0, 60), strip: :gps) == {:error, :malformed}

      xmp =
        "XML:com.adobe.xmp" <> <<0, 1, 0, 0, 0>> <> :zlib.compress(:binary.copy("x", 20_000_000))

      chunk = <<byte_size(xmp)::32, "iTXt", xmp::binary, :erlang.crc32(["iTXt", xmp])::32>>

      <<signature::binary-33, rest::binary>> =
        File.read!(Path.expand("../fixtures/small.png", __DIR__))

      assert PNG.edit(signature <> chunk <> rest, strip: :gps) == {:error, :malformed_exif}
    end
  end

  describe "WebP" do
    test "every change leaves the image's chunks byte for byte, an animation's frames too" do
      for webp <- [@webp, @simple, @animated], changes <- @changes do
        {:ok, edited} = WebP.edit(webp, changes)
        assert webp_image(edited) == webp_image(webp)
      end
    end

    test "strip(:gps) removes the location from Exif and XMP" do
      assert gps?(@webp)
      {:ok, stripped} = WebP.edit(@webp, strip: :gps)
      refute gps?(stripped)
      assert stripped =~ "Someone"
    end

    test "keep drops XMP, and the header says so" do
      {:ok, kept} = WebP.edit(@webp, strip: {:keep, [:copyright]})
      assert WebP.tags(kept) == {:ok, %{copyright: "Old Copyright"}}
      [{"VP8X", <<flags, _rest::binary>>} | chunks] = webp_chunks(kept)
      refute Enum.any?(chunks, &match?({"XMP ", _xml}, &1))
      assert Bitwise.band(flags, 0x04) == 0
      assert Bitwise.band(flags, 0x08) == 0x08
      assert Bitwise.band(flags, 0x20) == 0x20

      {:ok, none} = WebP.edit(@webp, strip: {:keep, [:lens_model]})
      [{"VP8X", <<flags, _rest::binary>>} | _chunks] = webp_chunks(none)
      assert Bitwise.band(flags, 0x0C) == 0
    end

    test "a simple WebP given Exif is given a header, with its size and alpha" do
      assert [{"VP8L", _image}] = webp_chunks(@simple)
      {:ok, put} = WebP.edit(@simple, put: %{artist: "Ana"})

      assert [{"VP8X", <<flags, 0::24, w::little-24, h::little-24>>}, {"VP8L", _}, {"EXIF", _}] =
               webp_chunks(put)

      assert {w + 1, h + 1} == {48, 32}
      assert flags == 0x10 + 0x08
      assert WebP.tags(put) == {:ok, %{artist: "Ana"}}
      assert WebP.edit(@simple, strip: :gps) == {:ok, @simple}
    end

    test "refuses what is not a WebP, and chunks cut short" do
      assert WebP.edit(@png, strip: :gps) == {:error, :not_webp}
      <<head::binary-12, rest::binary>> = @webp
      assert WebP.edit(head <> binary_part(rest, 0, 20), strip: :gps) == {:error, :malformed}
    end
  end

  describe "edit_file/3" do
    @tag :tmp_dir
    test "writes what edit/2 gives, for each format", %{tmp_dir: dir} do
      jpeg = File.read!(Path.join(@fixtures, "phone.jpg"))

      for {module, bytes} <- [
            {PNG, @png},
            {PNG, @apng},
            {WebP, @webp},
            {WebP, @simple},
            {WebP, @animated},
            {JPEG, jpeg}
          ],
          changes <- @changes do
        from = Path.join(dir, "from")
        to = Path.join(dir, "to")
        File.write!(from, bytes)
        File.rm(to)

        case module.edit_file(from, to, changes) do
          :ok -> assert {:ok, File.read!(to)} == module.edit(bytes, changes)
          :unchanged -> assert module.edit(bytes, changes) == {:ok, bytes}
        end
      end
    end
  end

  # Generated layouts of a PNG's metadata chunks, around small.png's image.

  defp text_chunk do
    gen all(
          type <- member_of(~w(tEXt zTXt iTXt)),
          keyword <-
            member_of(["Author", "Comment", "XML:com.adobe.xmp", "Raw profile type exif"]),
          gps <- boolean()
        ) do
      # GPS in XMP, and in the profiles ImageMagick writes, which go.
      text =
        if gps and keyword in ["XML:com.adobe.xmp", "Raw profile type exif"],
          do: ~s(<rdf:Description exif:GPSLatitude="41N"/>),
          else: "plain words"

      data =
        case type do
          "tEXt" -> keyword <> <<0>> <> text
          "zTXt" -> keyword <> <<0, 0>> <> :zlib.compress(text)
          "iTXt" -> keyword <> <<0, 1, 0, 0, 0>> <> :zlib.compress(text)
        end

      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
    end
  end

  property "editing a PNG never changes what draws it, and strip(:gps) leaves no GPS" do
    <<signature::binary-33, image::binary>> =
      File.read!(Path.expand("../fixtures/small.png", __DIR__))

    check all(texts <- list_of(text_chunk(), max_length: 5)) do
      png = signature <> IO.iodata_to_binary(texts) <> image

      {:ok, stripped} = PNG.edit(png, strip: :gps)
      assert png_image(stripped) == png_image(png)

      refute png_text(stripped) =~ "exif:GPS"
      refute stripped =~ "Raw profile type exif"

      {:ok, kept} = PNG.edit(png, strip: {:keep, [:artist]})
      assert png_image(kept) == png_image(png)

      {:ok, put} = PNG.edit(stripped, put: %{artist: "Ana"})
      assert png_image(put) == png_image(png)
      assert {:ok, %{artist: "Ana"}} = PNG.tags(put)
    end
  end
end
