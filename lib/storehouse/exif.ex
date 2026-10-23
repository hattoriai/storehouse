defmodule Storehouse.Exif do
  @moduledoc false
  # Exif, a TIFF of tags, as JPEG, PNG and WebP keep it: where a photo
  # was taken removed, only some tags kept, text tags written, read. The
  # formats' own modules (`Storehouse.JPEG`, `Storehouse.PNG`,
  # `Storehouse.WebP`) find it in the file, and give it here.

  @gps_ifd 0x8825
  @exif_ifd 0x8769

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

  @doc """
  The changes checked, before a byte is read: `{strip, put}`, `strip` as
  `nil`, `:gps` or `{:keep, codes, tags}`, `put` as a map or `nil`. Raises an
  ArgumentError for a change, a tag or a value Storehouse does not make.
  """
  def changes!(changes, module) do
    Enum.reduce(changes, {nil, nil}, fn
      {:strip, :gps}, {_strip, put} ->
        {:gps, put}

      {:strip, {:keep, tags}}, {_strip, put} when is_list(tags) ->
        {{:keep, codes(tags), tags}, put}

      {:put, tags}, {strip, _put} when is_map(tags) ->
        Enum.each(tags, &writable!/1)
        {strip, tags}

      other, _acc ->
        raise ArgumentError, "#{inspect(module)} makes no change #{inspect(other)}"
    end)
  end

  @doc """
  The TIFF with only the tags kept (`{:keep, codes}` from `changes!/2`),
  or `nil` when it has none of them.
  """
  def kept(tiff, {ifd0, exif}), do: kept_tiff(tiff, ifd0, exif)

  @doc """
  The TIFF (or `nil`, for a file with none) with these tags written, or
  removed when `nil`; `nil` when there is none and nothing is written.
  """
  def put(nil, tags) do
    case written(tags) do
      [] -> nil
      written -> new_tiff(:little, written)
    end
  end

  def put(tiff, tags), do: tiff_with(tiff, tags, written(tags))

  @doc "A text tag's name, of those `put` writes."
  def writable, do: @writable

  defp written(tags),
    do: for({tag, value} <- tags, value != nil, do: text(@ifd0_tags[tag], value))

  @doc "The named tags the TIFF has, decoded."
  def read(tiff) do
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

  @doc """
  `fun`'s result, or `{:error, :malformed_exif}` when a TIFF it reads
  cannot be read: it raises as it is read (`binary_part/3`, a match), and
  a file is refused, never cut short.
  """
  def safely(fun) do
    fun.()
  rescue
    _error in [ArgumentError, MatchError] -> {:error, :malformed_exif}
  end

  @doc "The TIFF without its GPS directory, zeroed in place: nothing else moves."
  def without_gps(tiff) do
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

  @doc "XMP without its GPS properties."
  def xmp_without_gps(xml) do
    xml
    |> String.replace(@xmp_gps_attribute, "")
    |> String.replace(@xmp_gps_element, "")
  end

  defp codes(tags) do
    Enum.reduce(tags, {[], []}, fn tag, {ifd0, exif} ->
      cond do
        code = @ifd0_tags[tag] -> {[code | ifd0], exif}
        code = @exif_tags[tag] -> {ifd0, [code | exif]}
        true -> raise ArgumentError, "Storehouse knows no tag #{inspect(tag)}"
      end
    end)
  end

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

  defp writable!({tag, value}) when tag in @writable and is_nil(value), do: :ok

  defp writable!({tag, value}) when tag in @writable and is_binary(value) do
    unless String.valid?(value) and not String.contains?(value, <<0>>),
      do: raise(ArgumentError, "#{inspect(tag)} must be UTF-8 text with no NUL byte")
  end

  defp writable!({tag, _value}),
    do: raise(ArgumentError, "Storehouse writes #{inspect(@writable)}, not #{inspect(tag)}")

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

  # TIFF

  def header!(<<"II", 42::little-16, ifd::little-32, _rest::binary>>), do: {:little, ifd}
  def header!(<<"MM", 42::big-16, ifd::big-32, _rest::binary>>), do: {:big, ifd}
  def header!(_tiff), do: raise(ArgumentError, "not a TIFF")

  defp tiff_header(:little), do: <<"II", 42::little-16, 8::little-32>>
  defp tiff_header(:big), do: <<"MM", 42::big-16, 8::big-32>>

  defp new_tiff(endian, entries),
    do: tiff_header(endian) <> encode_ifd(entries, 8, endian, 0)

  # A directory's entries, `{tag, type, count, value field}`, and the
  # offset of the next directory.
  def ifd!(tiff, at, endian) do
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

  def uint(<<n::little-16>>, :little), do: n
  def uint(<<n::big-16>>, :big), do: n
  def uint(<<n::little-32>>, :little), do: n
  def uint(<<n::big-32>>, :big), do: n

  def uint_bytes(n, bytes, :little), do: <<n::little-size(bytes * 8)>>
  def uint_bytes(n, bytes, :big), do: <<n::big-size(bytes * 8)>>

  defp pad(binary, size), do: binary <> :binary.copy(<<0>>, size - byte_size(binary))

  def overwrite(binary, at, bytes) do
    after_at = at + byte_size(bytes)

    binary_part(binary, 0, at) <>
      bytes <> binary_part(binary, after_at, byte_size(binary) - after_at)
  end
end
