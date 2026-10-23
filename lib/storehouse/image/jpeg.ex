defmodule Storehouse.Image.JPEG do
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

      {:ok, jpeg} = Storehouse.Image.JPEG.strip(jpeg, :gps)
      {:ok, jpeg} = Storehouse.Image.JPEG.strip(jpeg, {:keep, [:orientation, :copyright]})
      {:ok, jpeg} = Storehouse.Image.JPEG.put_tags(jpeg, %{artist: "Ana Sousa", copyright: "© Ana Sousa"})

  `edit_file/3` does the same from a file to a file, with only the
  metadata in memory: what `Storehouse.Image.MetadataEditor.Builtin`, the
  default editor of the `Storehouse.Analyzer.EditMetadata` step, uses.

  Nothing in Storehouse calls these on its own: a stored file's bytes
  change only when the app asks, with these functions or that step.

  ## Tags

  By name, from the first directory (IFD0): #{Enum.map_join(~w(orientation artist copyright image_description make model software date_time x_resolution y_resolution resolution_unit), ", ", &"`:#{&1}`")};
  and from the Exif directory: #{Enum.map_join(~w(date_time_original offset_time_original exposure_time f_number iso focal_length lens_make lens_model color_space), ", ", &"`:#{&1}`")}.

  ## What is left as it is

    * Data after the end of the image: a phone's gain map or depth map,
      a second picture its MPF segment lists. Its offsets are kept right
      when segments before it change size.
    * Place names: `strip(jpeg, :gps)` removes coordinates, not a city an
      app or a person wrote in IPTC or XMP.
    * Other formats: these functions refuse them with `{:error,
      :not_jpeg}`. `Storehouse.Image.PNG` and `Storehouse.Image.WebP` edit those two
      the same way; HEIC and TIFF are left to another editor
      (`Storehouse.Image.MetadataEditor`).

  A JPEG whose segments or Exif cannot be read is refused with `{:error,
  :malformed}` or `{:error, :malformed_exif}`, never cut short.
  """

  alias Storehouse.Image.Exif

  @exif "Exif\0\0"
  @xmp "http://ns.adobe.com/xap/1.0/\0"
  @xmp_extension "http://ns.adobe.com/xmp/extension/\0"

  @mp_entry 0xB002

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
  def strip(jpeg, what) when is_binary(jpeg), do: edit(jpeg, strip: what)

  @doc """
  The JPEG with these tags written, or removed when `nil`: `:artist`,
  `:copyright` and `:image_description`, as UTF-8 text, the way ExifTool
  writes it (a reader that takes Exif text as Latin-1 shows letters past
  ASCII wrongly). A JPEG with no Exif is given one.

  The tags it replaces and their old directory are zeroed, so an old name
  does not stay in the file.

  ## Examples

      iex> {:ok, jpeg} = Storehouse.Image.JPEG.put_tags(File.read!("test/fixtures/harbour.jpg"), %{artist: "Ana"})
      iex> Storehouse.Image.JPEG.tags(jpeg)
      {:ok, %{artist: "Ana"}}

  """
  @spec put_tags(binary(), %{optional(tag()) => String.t() | nil}) ::
          {:ok, binary()} | {:error, reason()}
  def put_tags(jpeg, tags) when is_binary(jpeg) and is_map(tags), do: edit(jpeg, put: tags)

  @doc """
  The JPEG with `changes` made: `:strip` (as `strip/2`), then `:put` (as
  `put_tags/2`).
  """
  @spec edit(binary(), Storehouse.Image.MetadataEditor.changes()) ::
          {:ok, binary()} | {:error, reason()}
  def edit(jpeg, changes) when is_binary(jpeg) and is_list(changes) do
    change = changer(changes)

    with {:ok, segments, tail} <- parse(jpeg),
         {:ok, edited} <- Exif.safely(fn -> {:ok, change.(segments)} end) do
      if edited == segments,
        do: {:ok, jpeg},
        else: encode(mpf_moved(segments, edited), tail)
    end
  end

  @doc """
  The JPEG at `from`, with `changes` made (as `edit/2`), written to `to`.

  Only its metadata is read into memory: the image data, most of the
  file, is copied from file to file, so a photo of any size takes the
  memory of its metadata. `:unchanged` when there is nothing to change,
  and `to` is not written.
  """
  @spec edit_file(Path.t(), Path.t(), Storehouse.Image.MetadataEditor.changes()) ::
          :ok | :unchanged | {:error, reason() | File.posix()}
  def edit_file(from, to, changes) when is_list(changes) do
    change = changer(changes)

    case File.open(from, [:read, :raw, :binary, :read_ahead], &edit_into(&1, to, change)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp edit_into(input, to, change) do
    with {:ok, segments, image_at} <- read_head(input),
         {:ok, edited} <- Exif.safely(fn -> {:ok, change.(segments)} end) do
      if edited == segments,
        do: :unchanged,
        else: write_file(input, image_at, mpf_moved(segments, edited), to)
    end
  end

  # The changes as one function of the segments, checked before a byte is
  # read: what to strip, then what to write.
  defp changer(changes) do
    {strip, put} = Exif.changes!(changes, __MODULE__)

    fn segments ->
      segments =
        case strip do
          nil -> segments
          :gps -> Enum.flat_map(segments, &strip_gps/1)
          {:keep, codes, _tags} -> Enum.flat_map(segments, &keep(&1, codes))
        end

      if put, do: put_exif(segments, put), else: segments
    end
  end

  @doc """
  The named tags (see Tags) the JPEG's Exif has, decoded: text as a
  string, numbers as integers, fractions as `{numerator, denominator}`.
  `%{}` for a JPEG with no Exif.
  """
  @spec tags(binary()) :: {:ok, %{tag() => term()}} | {:error, reason()}
  def tags(jpeg) when is_binary(jpeg) do
    with {:ok, segments, _tail} <- parse(jpeg) do
      Exif.safely(fn -> {:ok, segments |> Enum.find(&exif?/1) |> read_tags()} end)
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

  # The same segments, read from a file: up to the image data, and where
  # it starts.
  defp read_head(io) do
    case :file.read(io, 2) do
      {:ok, <<0xFF, 0xD8>>} -> read_segments(io, 2, [])
      _other -> {:error, :not_jpeg}
    end
  end

  defp read_segments(io, at, acc) do
    case :file.read(io, 2) do
      {:ok, <<0xFF, 0xFF>>} ->
        {:ok, _at} = :file.position(io, at + 1)
        read_segments(io, at + 1, acc)

      {:ok, <<0xFF, marker>>} when marker in [0xDA, 0xD9] ->
        {:ok, Enum.reverse(acc), at}

      {:ok, <<0xFF, marker>>} when marker == 0x01 or marker in 0xD0..0xD7 ->
        read_segments(io, at + 2, [{marker, nil} | acc])

      {:ok, <<0xFF, marker>>} ->
        read_segment(io, at, marker, acc)

      _other ->
        {:error, :malformed}
    end
  end

  defp read_segment(io, at, marker, acc) do
    with {:ok, <<length::16>>} when length >= 2 <- :file.read(io, 2),
         {:ok, payload} <- read_exact(io, length - 2) do
      read_segments(io, at + 2 + length, [{marker, payload} | acc])
    else
      _short -> {:error, :malformed}
    end
  end

  defp read_exact(_io, 0), do: {:ok, ""}

  defp read_exact(io, size) do
    case :file.read(io, size) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _short -> :error
    end
  end

  # The new segments, then the image data copied as it is.
  defp write_file(input, image_at, segments, to) do
    with {:ok, head} <- encode_head(segments),
         {:ok, ^image_at} <- :file.position(input, image_at),
         {:ok, {:ok, _bytes}} <- File.open(to, [:write, :raw, :binary], &copy(&1, head, input)) do
      :ok
    end
  end

  defp copy(output, head, input) do
    with :ok <- :file.write(output, head), do: :file.copy(input, output)
  end

  defp encode(segments, tail) do
    with {:ok, head} <- encode_head(segments), do: {:ok, IO.iodata_to_binary([head, tail])}
  end

  defp encode_head(segments) do
    if Enum.any?(segments, fn {_marker, payload} -> byte_size(payload || "") > 65_533 end),
      do: {:error, :exif_too_large},
      else: {:ok, IO.iodata_to_binary([<<0xFF, 0xD8>>, Enum.map(segments, &segment/1)])}
  end

  defp segment({marker, nil}), do: <<0xFF, marker>>

  defp segment({marker, payload}),
    do: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>

  defp exif?({0xE1, @exif <> _tiff}), do: true
  defp exif?(_segment), do: false

  # strip(:gps)

  defp strip_gps({0xE1, @exif <> tiff}), do: [{0xE1, @exif <> Exif.without_gps(tiff)}]

  defp strip_gps({0xE1, @xmp <> xml}), do: [{0xE1, @xmp <> Exif.xmp_without_gps(xml)}]

  # An extended XMP's parts are split anywhere: dropped when they hold GPS
  # properties, which cannot be edited across the split.
  defp strip_gps({0xE1, @xmp_extension <> part} = segment),
    do: if(String.contains?(part, "GPS"), do: [], else: [segment])

  defp strip_gps(segment), do: [segment]

  # strip({:keep, tags})

  defp keep({0xE1, @exif <> tiff}, codes) do
    case Exif.kept(tiff, codes) do
      nil -> []
      tiff -> [{0xE1, @exif <> tiff}]
    end
  end

  defp keep({0xE0, "JFIF\0" <> _header} = segment, _codes), do: [segment]
  defp keep({0xE2, "ICC_PROFILE\0" <> _profile} = segment, _codes), do: [segment]
  defp keep({0xE2, "MPF\0" <> _index} = segment, _codes), do: [segment]
  defp keep({0xEE, "Adobe" <> _transform} = segment, _codes), do: [segment]

  defp keep({marker, _payload}, _codes) when marker in 0xE0..0xEF or marker == 0xFE, do: []

  defp keep(segment, _codes), do: [segment]

  # put_tags

  defp put_exif(segments, tags) do
    case Enum.find_index(segments, &exif?/1) do
      nil ->
        insert_exif(segments, Exif.put(nil, tags))

      index ->
        List.update_at(segments, index, fn {0xE1, @exif <> tiff} ->
          {0xE1, @exif <> Exif.put(tiff, tags)}
        end)
    end
  end

  defp insert_exif(segments, nil), do: segments

  # After the JFIF header, which must come first.
  defp insert_exif(segments, tiff) do
    at = if match?([{0xE0, "JFIF\0" <> _header} | _rest], segments), do: 1, else: 0
    List.insert_at(segments, at, {0xE1, @exif <> tiff})
  end

  defp read_tags(nil), do: %{}
  defp read_tags({_marker, @exif <> tiff}), do: Exif.read(tiff)

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
    {endian, ifd} = Exif.header!(tiff)
    {entries, _next} = Exif.ifd!(tiff, ifd, endian)

    case List.keyfind(entries, @mp_entry, 0) do
      {_tag, 7, count, value} when count > 4 ->
        at = Exif.uint(value, endian)

        Enum.reduce(0..(div(count, 16) - 1)//1, tiff, fn i, tiff ->
          move_entry(tiff, at + i * 16 + 8, delta, endian)
        end)

      _none ->
        tiff
    end
  end

  # An entry's offset, 0 for the first picture, which does not move.
  defp move_entry(tiff, field, delta, endian) do
    case Exif.uint(binary_part(tiff, field, 4), endian) do
      0 -> tiff
      offset -> Exif.overwrite(tiff, field, Exif.uint_bytes(offset + delta, 4, endian))
    end
  end
end
