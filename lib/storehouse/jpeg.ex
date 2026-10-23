defmodule Storehouse.JPEG do
  @moduledoc """
  Edits the metadata inside a JPEG without re-encoding it: removes where a
  photo was taken, keeps only a few tags, or writes an author's name, and
  never touches the image's data.

  A JPEG's metadata lives in segments of its own, before the image data:
  Exif (APP1), XMP (APP1), IPTC (APP13), comments. These functions rewrite
  those segments and copy everything else, the tables and the compressed
  image, byte for byte, so the pixels a reader decodes are the same ones.
  Re-encoding with an image library (libvips, ImageMagick) would lose
  quality and change the file.

      {:ok, jpeg} = Storehouse.JPEG.strip(jpeg, :gps)
      {:ok, jpeg} = Storehouse.JPEG.strip(jpeg, {:keep, [:orientation, :copyright]})
      {:ok, jpeg} = Storehouse.JPEG.put_tags(jpeg, %{artist: "Ana Sousa", copyright: "© Ana Sousa"})

  Nothing in Storehouse calls these on its own: a stored file's bytes
  change only when the app asks, with these functions or the
  `Storehouse.Analyzer.EditMetadata` step.

  ## Tags

  By name, from the first directory (IFD0): #{Enum.map_join(~w(orientation artist copyright image_description make model software date_time x_resolution y_resolution resolution_unit), ", ", &"`:#{&1}`")};
  and from the Exif directory: #{Enum.map_join(~w(date_time_original offset_time_original exposure_time f_number iso focal_length lens_make lens_model color_space), ", ", &"`:#{&1}`")}.

  ## What is left as it is

    * Data after the end of the image: a phone's gain map or depth map,
      a second picture its MPF segment lists. Its offsets are kept right
      when segments before it change size.
    * Place names: `strip(jpeg, :gps)` removes coordinates, not a city an
      app or a person wrote in IPTC or XMP.
    * Other formats: PNG, WebP, HEIC and TIFF are not JPEGs, and these
      functions refuse them with `{:error, :not_jpeg}`.

  A JPEG whose segments or Exif cannot be read is refused with `{:error,
  :malformed}` or `{:error, :malformed_exif}`, never cut short.
  """

  @exif "Exif\0\0"
  @xmp "http://ns.adobe.com/xap/1.0/\0"
  @xmp_extension "http://ns.adobe.com/xmp/extension/\0"

  @gps_ifd 0x8825
  @exif_ifd 0x8769
  @mp_entry 0xB002

  @ifd0_tags %{
    orientation: 0x0112,
    artist: 0x013B,
    copyright: 0x8298,
    image_description: 0x010E,
    make: 0x010F,
    model: 0x0110,
    software: 0x0131,
    date_time: 0x0132,
    x_resolution: 0x011A,
    y_resolution: 0x011B,
    resolution_unit: 0x0128
  }

  @exif_tags %{
    date_time_original: 0x9003,
    offset_time_original: 0x9011,
    exposure_time: 0x829A,
    f_number: 0x829D,
    iso: 0x8827,
    focal_length: 0x920A,
    lens_make: 0xA433,
    lens_model: 0xA434,
    color_space: 0xA001
  }

  @writable [:artist, :copyright, :image_description]

  # The bytes of one value of each TIFF type.
  @type_sizes %{
    1 => 1,
    2 => 1,
    3 => 2,
    4 => 4,
    5 => 8,
    6 => 1,
    7 => 1,
    8 => 2,
    9 => 4,
    10 => 8,
    11 => 4,
    12 => 8,
    13 => 4
  }

  @typedoc "A tag, by name (see Tags)."
  @type tag :: atom()

  @typedoc "Why a JPEG is refused."
  @type reason :: :not_jpeg | :malformed | :malformed_exif | :exif_too_large

  @doc """
  The JPEG without the metadata `what` names:

    * `:gps` - where it was taken: the Exif GPS directory, and the GPS
      properties of its XMP. The bytes they held are zeroed, not only
      unlinked. Everything else stays where it is.
    * `{:keep, tags}` - every tag but those named (see Tags), and all of
      XMP, IPTC, comments and the Exif thumbnail. What draws the image
      stays: the JFIF header, the ICC colour profile, Adobe's colour
      transform and the MPF index. XMP holds a phone's HDR gain map
      description too, which goes with it.

  A JPEG with nothing to remove is given back as it was, byte for byte.
  """
  @spec strip(binary(), :gps | {:keep, [tag()]}) :: {:ok, binary()} | {:error, reason()}
  def strip(jpeg, :gps) when is_binary(jpeg) do
    edit(jpeg, fn segments -> Enum.flat_map(segments, &strip_gps/1) end)
  end

  def strip(jpeg, {:keep, tags}) when is_binary(jpeg) and is_list(tags) do
    {ifd0, exif} = codes(tags)
    edit(jpeg, fn segments -> Enum.flat_map(segments, &keep(&1, ifd0, exif)) end)
  end

  @doc """
  The JPEG with these tags written, or removed when `nil`: `:artist`,
  `:copyright` and `:image_description`, as UTF-8 text, the way ExifTool
  writes it (a reader that takes Exif text as Latin-1 shows letters past
  ASCII wrongly). A JPEG with no Exif is given one.

  The tags it replaces and their old directory are zeroed, so an old name
  does not stay in the file.

  ## Examples

      iex> {:ok, jpeg} = Storehouse.JPEG.put_tags(File.read!("test/fixtures/harbour.jpg"), %{artist: "Ana"})
      iex> Storehouse.JPEG.tags(jpeg)
      {:ok, %{artist: "Ana"}}

  """
  @spec put_tags(binary(), %{optional(tag()) => String.t() | nil}) ::
          {:ok, binary()} | {:error, reason()}
  def put_tags(jpeg, tags) when is_binary(jpeg) and is_map(tags) do
    Enum.each(tags, &writable!/1)
    edit(jpeg, &put_exif(&1, tags))
  end

  @doc """
  The named tags (see Tags) the JPEG's Exif has, decoded: text as a
  string, numbers as integers, fractions as `{numerator, denominator}`.
  `%{}` for a JPEG with no Exif.
  """
  @spec tags(binary()) :: {:ok, %{tag() => term()}} | {:error, reason()}
  def tags(jpeg) when is_binary(jpeg) do
    with {:ok, segments, _tail} <- parse(jpeg) do
      safely(fn -> {:ok, segments |> Enum.find(&exif?/1) |> read_tags()} end)
    end
  end

  # Segments: the markers up to the start of the image data, each with
  # its payload (`nil` for a marker that has none), and the rest as it is.

  defp parse(<<0xFF, 0xD8, rest::binary>>), do: segments(rest, [])
  defp parse(_other), do: {:error, :not_jpeg}

  defp segments(<<0xFF, 0xFF, rest::binary>>, acc), do: segments(<<0xFF, rest::binary>>, acc)

  defp segments(<<0xFF, marker, _rest::binary>> = tail, acc) when marker in [0xDA, 0xD9],
    do: {:ok, Enum.reverse(acc), tail}

  defp segments(<<0xFF, marker, rest::binary>>, acc) when marker == 0x01 or marker in 0xD0..0xD7,
    do: segments(rest, [{marker, nil} | acc])

  defp segments(<<0xFF, marker, length::16, rest::binary>>, acc) when length >= 2 do
    size = length - 2

    case rest do
      <<payload::binary-size(^size), next::binary>> -> segments(next, [{marker, payload} | acc])
      _short -> {:error, :malformed}
    end
  end

  defp segments(_other, _acc), do: {:error, :malformed}

  defp edit(jpeg, fun) do
    with {:ok, segments, tail} <- parse(jpeg),
         {:ok, edited} <- safely(fn -> {:ok, fun.(segments)} end) do
      if edited == segments,
        do: {:ok, jpeg},
        else: encode(mpf_moved(segments, edited), tail)
    end
  end

  defp encode(segments, tail) do
    if Enum.any?(segments, fn {_marker, payload} -> byte_size(payload || "") > 65_533 end),
      do: {:error, :exif_too_large},
      else: {:ok, IO.iodata_to_binary([<<0xFF, 0xD8>>, Enum.map(segments, &segment/1), tail])}
  end

  defp segment({marker, nil}), do: <<0xFF, marker>>

  defp segment({marker, payload}),
    do: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>

  # A TIFF that cannot be read raises as it is read (`binary_part/3`, a
  # match): refused as malformed, never cut short.
  defp safely(fun) do
    fun.()
  rescue
    _error in [ArgumentError, MatchError] -> {:error, :malformed_exif}
  end

  defp exif?({0xE1, @exif <> _tiff}), do: true
  defp exif?(_segment), do: false

  # strip(:gps)

  defp strip_gps({0xE1, @exif <> tiff}), do: [{0xE1, @exif <> without_gps(tiff)}]

  defp strip_gps({0xE1, @xmp <> xml}), do: [{0xE1, @xmp <> xmp_without_gps(xml)}]

  # An extended XMP's parts are split anywhere: dropped when they hold GPS
  # properties, which cannot be edited across the split.
  defp strip_gps({0xE1, @xmp_extension <> part} = segment),
    do: if(String.contains?(part, "GPS"), do: [], else: [segment])

  defp strip_gps(segment), do: [segment]

  defp without_gps(tiff) do
    {endian, ifd0} = header!(tiff)
    {entries, next} = ifd!(tiff, ifd0, endian)

    case Enum.split_with(entries, &(elem(&1, 0) == @gps_ifd)) do
      {[], _entries} ->
        tiff

      {gps, others} ->
        tiff =
          Enum.reduce(gps, tiff, fn {_tag, _type, _count, at}, tiff ->
            blank_ifd(tiff, uint(at, endian), endian)
          end)

        # The directory in place, without the GPS entry: nothing else moves.
        directory = encode_ifd(raw(others), ifd0, endian, next)
        overwrite(tiff, ifd0, pad(directory, 6 + 12 * length(entries)))
    end
  end

  # A directory and the values it points to, zeroed.
  defp blank_ifd(tiff, at, endian) do
    {entries, _next} = ifd!(tiff, at, endian)

    tiff
    |> blank_values(entries, endian)
    |> overwrite(at, :binary.copy(<<0>>, 6 + 12 * length(entries)))
  end

  # The values longer than four bytes these entries point to, zeroed.
  defp blank_values(tiff, entries, endian) do
    Enum.reduce(entries, tiff, fn {_tag, type, count, value}, tiff ->
      case value_size(type, count) do
        size when is_integer(size) and size > 4 ->
          overwrite(tiff, uint(value, endian), :binary.copy(<<0>>, size))

        _inline ->
          tiff
      end
    end)
  end

  @xmp_gps_attribute ~r/\s+exif:GPS\w*\s*=\s*("[^"]*"|'[^']*')/
  @xmp_gps_element ~r{<exif:(GPS\w*)\b[^>]*?(/>|>.*?</exif:\1\s*>)}s

  defp xmp_without_gps(xml) do
    xml
    |> String.replace(@xmp_gps_attribute, "")
    |> String.replace(@xmp_gps_element, "")
  end

  # strip({:keep, tags})

  defp codes(tags) do
    Enum.reduce(tags, {[], []}, fn tag, {ifd0, exif} ->
      cond do
        code = @ifd0_tags[tag] -> {[code | ifd0], exif}
        code = @exif_tags[tag] -> {ifd0, [code | exif]}
        true -> raise ArgumentError, "Storehouse.JPEG knows no tag #{inspect(tag)}"
      end
    end)
  end

  defp keep({0xE1, @exif <> tiff}, ifd0, exif) do
    case kept_tiff(tiff, ifd0, exif) do
      nil -> []
      tiff -> [{0xE1, @exif <> tiff}]
    end
  end

  defp keep({0xE0, "JFIF\0" <> _header} = segment, _ifd0, _exif), do: [segment]
  defp keep({0xE2, "ICC_PROFILE\0" <> _profile} = segment, _ifd0, _exif), do: [segment]
  defp keep({0xE2, "MPF\0" <> _index} = segment, _ifd0, _exif), do: [segment]
  defp keep({0xEE, "Adobe" <> _transform} = segment, _ifd0, _exif), do: [segment]

  defp keep({marker, _payload}, _ifd0, _exif) when marker in 0xE0..0xEF or marker == 0xFE,
    do: []

  defp keep(segment, _ifd0, _exif), do: [segment]

  # A new TIFF with only the tags kept, or `nil` when it has none of them.
  defp kept_tiff(tiff, ifd0_codes, exif_codes) do
    {endian, ifd0} = header!(tiff)
    {entries, _next} = ifd!(tiff, ifd0, endian)

    exif =
      case List.keyfind(entries, @exif_ifd, 0) do
        {_tag, _type, _count, at} -> tiff |> ifd!(uint(at, endian), endian) |> elem(0)
        nil -> []
      end

    kept0 = values(tiff, entries, ifd0_codes, endian)
    kept_exif = values(tiff, exif, exif_codes, endian)

    cond do
      kept0 == [] and kept_exif == [] ->
        nil

      kept_exif == [] ->
        new_tiff(endian, kept0)

      true ->
        # IFD0 first, with the Exif directory's place, then the Exif directory.
        pointer = {@exif_ifd, 4, 1, <<0::32>>}
        exif_at = 8 + byte_size(encode_ifd([pointer | kept0], 8, endian, 0))
        pointer = {@exif_ifd, 4, 1, uint_bytes(exif_at, 4, endian)}

        IO.iodata_to_binary([
          tiff_header(endian),
          encode_ifd([pointer | kept0], 8, endian, 0),
          encode_ifd(kept_exif, exif_at, endian, 0)
        ])
    end
  end

  defp values(tiff, entries, codes, endian) do
    for {tag, type, count, value} <- entries,
        tag in codes,
        size = value_size(type, count),
        size != nil,
        do: {tag, type, count, value_bytes(tiff, value, size, endian)}
  end

  # put_tags

  defp writable!({tag, value}) when tag in @writable and is_nil(value), do: :ok

  defp writable!({tag, value}) when tag in @writable and is_binary(value) do
    unless String.valid?(value) and not String.contains?(value, <<0>>),
      do: raise(ArgumentError, "#{inspect(tag)} must be UTF-8 text with no NUL byte")
  end

  defp writable!({tag, _value}),
    do: raise(ArgumentError, "Storehouse.JPEG writes #{inspect(@writable)}, not #{inspect(tag)}")

  defp put_exif(segments, tags) do
    written = for {tag, value} <- tags, value != nil, do: text(@ifd0_tags[tag], value)

    case Enum.find_index(segments, &exif?/1) do
      nil when written == [] ->
        segments

      nil ->
        # After the JFIF header, which must come first.
        at = if match?([{0xE0, "JFIF\0" <> _header} | _rest], segments), do: 1, else: 0
        List.insert_at(segments, at, {0xE1, @exif <> new_tiff(:little, written)})

      index ->
        List.update_at(segments, index, fn {0xE1, @exif <> tiff} ->
          {0xE1, @exif <> tiff_with(tiff, tags, written)}
        end)
    end
  end

  defp text(code, value), do: {code, 2, byte_size(value) + 1, value <> <<0>>}

  # The TIFF with a new IFD0 at its end: the entries it keeps as they
  # were, pointing where they did, and those written. The old directory,
  # and the values of the tags replaced, are zeroed.
  defp tiff_with(tiff, tags, written) do
    {endian, ifd0} = header!(tiff)
    {entries, next} = ifd!(tiff, ifd0, endian)
    codes = for {tag, _value} <- tags, do: @ifd0_tags[tag]
    {replaced, kept} = Enum.split_with(entries, &(elem(&1, 0) in codes))

    if replaced == [] and written == [] do
      tiff
    else
      tiff =
        tiff
        |> blank_values(replaced, endian)
        |> overwrite(ifd0, :binary.copy(<<0>>, 6 + 12 * length(entries)))

      tiff = pad(tiff, byte_size(tiff) + rem(byte_size(tiff), 2))
      at = byte_size(tiff)

      tiff
      |> Kernel.<>(encode_ifd(raw(kept) ++ written, at, endian, next))
      |> overwrite(4, uint_bytes(at, 4, endian))
    end
  end

  # Reading

  defp read_tags(nil), do: %{}

  defp read_tags({_marker, @exif <> tiff}) do
    {endian, ifd0} = header!(tiff)
    {entries, _next} = ifd!(tiff, ifd0, endian)

    exif =
      case List.keyfind(entries, @exif_ifd, 0) do
        {_tag, _type, _count, at} -> tiff |> ifd!(uint(at, endian), endian) |> elem(0)
        nil -> []
      end

    Map.merge(decoded(tiff, entries, @ifd0_tags, endian), decoded(tiff, exif, @exif_tags, endian))
  end

  defp decoded(tiff, entries, names, endian) do
    by_code = Map.new(names, fn {name, code} -> {code, name} end)

    for {tag, type, count, value} <- entries,
        name = by_code[tag],
        size = value_size(type, count),
        size != nil,
        decoded = decode(type, value_bytes(tiff, value, size, endian), endian),
        decoded != nil,
        into: %{},
        do: {name, decoded}
  end

  defp decode(2, bytes, _endian), do: bytes |> :binary.split(<<0>>) |> hd()
  defp decode(3, <<n::binary-2>>, endian), do: uint(n, endian)
  defp decode(4, <<n::binary-4>>, endian), do: uint(n, endian)

  defp decode(5, <<n::binary-4, d::binary-4>>, endian), do: {uint(n, endian), uint(d, endian)}

  defp decode(_type, _bytes, _endian), do: nil

  # TIFF

  defp header!(<<"II", 42::little-16, ifd::little-32, _rest::binary>>), do: {:little, ifd}
  defp header!(<<"MM", 42::big-16, ifd::big-32, _rest::binary>>), do: {:big, ifd}
  defp header!(_tiff), do: raise(ArgumentError, "not a TIFF")

  defp tiff_header(:little), do: <<"II", 42::little-16, 8::little-32>>
  defp tiff_header(:big), do: <<"MM", 42::big-16, 8::big-32>>

  defp new_tiff(endian, entries),
    do: tiff_header(endian) <> encode_ifd(entries, 8, endian, 0)

  # A directory's entries, `{tag, type, count, value field}`, and the
  # offset of the next directory.
  defp ifd!(tiff, at, endian) do
    count = uint(binary_part(tiff, at, 2), endian)

    entries =
      for i <- 0..(count - 1)//1 do
        <<tag::binary-2, type::binary-2, n::binary-4, value::binary-4>> =
          binary_part(tiff, at + 2 + i * 12, 12)

        {uint(tag, endian), uint(type, endian), uint(n, endian), value}
      end

    {entries, uint(binary_part(tiff, at + 2 + count * 12, 4), endian)}
  end

  defp value_size(type, count) do
    case @type_sizes do
      %{^type => size} -> size * count
      _unknown -> nil
    end
  end

  # A value of at most four bytes is in the entry itself; a longer one is
  # where the entry points.
  defp value_bytes(_tiff, value, size, _endian) when size <= 4, do: binary_part(value, 0, size)
  defp value_bytes(tiff, value, size, endian), do: binary_part(tiff, uint(value, endian), size)

  # Entries copied as they are: their values stay where they were.
  defp raw(entries),
    do: for({tag, type, count, value} <- entries, do: {tag, type, count, {:raw, value}})

  # A directory at `at`, its entries in the order of their tags, the
  # values longer than four bytes after it, each at an even offset.
  defp encode_ifd(entries, at, endian, next) do
    entries = Enum.sort_by(entries, &elem(&1, 0))
    data_at = at + 6 + 12 * length(entries)

    {fields, data, _at} =
      Enum.reduce(entries, {[], [], data_at}, fn
        {tag, type, count, {:raw, value}}, {fields, data, offset} ->
          {[field(tag, type, count, value, endian) | fields], data, offset}

        {tag, type, count, bytes}, {fields, data, offset} when byte_size(bytes) <= 4 ->
          {[field(tag, type, count, pad(bytes, 4), endian) | fields], data, offset}

        {tag, type, count, bytes}, {fields, data, offset} ->
          bytes = pad(bytes, byte_size(bytes) + rem(byte_size(bytes), 2))
          pointer = uint_bytes(offset, 4, endian)

          {[field(tag, type, count, pointer, endian) | fields], [bytes | data],
           offset + byte_size(bytes)}
      end)

    IO.iodata_to_binary([
      uint_bytes(length(entries), 2, endian),
      Enum.reverse(fields),
      uint_bytes(next, 4, endian),
      Enum.reverse(data)
    ])
  end

  defp field(tag, type, count, value, endian),
    do: [
      uint_bytes(tag, 2, endian),
      uint_bytes(type, 2, endian),
      uint_bytes(count, 4, endian),
      value
    ]

  defp uint(<<n::little-16>>, :little), do: n
  defp uint(<<n::big-16>>, :big), do: n
  defp uint(<<n::little-32>>, :little), do: n
  defp uint(<<n::big-32>>, :big), do: n

  defp uint_bytes(n, bytes, :little), do: <<n::little-size(bytes * 8)>>
  defp uint_bytes(n, bytes, :big), do: <<n::big-size(bytes * 8)>>

  defp pad(binary, size), do: binary <> :binary.copy(<<0>>, size - byte_size(binary))

  defp overwrite(binary, at, bytes) do
    after_at = at + byte_size(bytes)

    binary_part(binary, 0, at) <>
      bytes <> binary_part(binary, after_at, byte_size(binary) - after_at)
  end

  # MPF: a phone's index of the pictures after the image's end, by their
  # offset from the MPF segment. When the segments after it change size,
  # those offsets move by as much.
  defp mpf_moved(old, new) do
    with old_after when old_after != nil <- after_mpf(old),
         new_after when new_after != nil <- after_mpf(new),
         delta when delta != 0 <- new_after - old_after do
      Enum.map(new, fn
        {0xE2, "MPF\0" <> tiff} -> {0xE2, "MPF\0" <> safe_moved(tiff, delta)}
        segment -> segment
      end)
    else
      _same -> new
    end
  end

  defp after_mpf(segments) do
    case Enum.split_while(segments, &(not match?({0xE2, "MPF\0" <> _index}, &1))) do
      {_before, [_mpf | rest]} -> rest |> Enum.map(&byte_size(segment(&1))) |> Enum.sum()
      {_all, []} -> nil
    end
  end

  # An index that cannot be read is left as it is.
  defp safe_moved(tiff, delta) do
    moved(tiff, delta)
  rescue
    _error in [ArgumentError, MatchError] -> tiff
  end

  defp moved(tiff, delta) do
    {endian, ifd} = header!(tiff)
    {entries, _next} = ifd!(tiff, ifd, endian)

    case List.keyfind(entries, @mp_entry, 0) do
      {_tag, 7, count, value} when count > 4 ->
        at = uint(value, endian)

        Enum.reduce(0..(div(count, 16) - 1)//1, tiff, fn i, tiff ->
          move_entry(tiff, at + i * 16 + 8, delta, endian)
        end)

      _none ->
        tiff
    end
  end

  # An entry's offset, 0 for the first picture, which does not move.
  defp move_entry(tiff, field, delta, endian) do
    case uint(binary_part(tiff, field, 4), endian) do
      0 -> tiff
      offset -> overwrite(tiff, field, uint_bytes(offset + delta, 4, endian))
    end
  end
end
