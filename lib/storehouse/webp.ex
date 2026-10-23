defmodule Storehouse.WebP do
  @moduledoc """
  Edits the metadata inside a WebP without re-encoding it, as
  `Storehouse.JPEG` does a JPEG's: the same changes, the same tags.

  A WebP keeps its metadata in chunks of its own, `EXIF` and `XMP `,
  which the `VP8X` header lists. These functions rewrite those chunks and
  the header's flags, and copy every other chunk, the image and what
  draws it (alpha, the colour profile, an animation's frames), byte for
  byte.

    * `strip: :gps` - the Exif GPS directory, zeroed, and XMP's GPS
      properties.
    * `strip: {:keep, tags}` - Exif with only the tags named, and no XMP
      or chunk of another app's.
    * `put: %{artist: _, copyright: _, image_description: _}` - written
      into Exif. A simple WebP, which has no `VP8X` header, is given one,
      from its image's size.

  `edit_file/3` reads only the metadata chunks into memory. A WebP whose
  chunks cannot be read is refused with `{:error, :malformed}`, one whose
  Exif cannot be read with `{:error, :malformed_exif}`.
  """

  import Bitwise

  alias Storehouse.{Container, Exif}

  @metadata ["VP8X", "EXIF", "XMP "]
  # What draws the image: kept by `strip: {:keep, tags}`.
  @image ["VP8X", "ICCP", "ANIM", "ANMF", "ALPH", "VP8 ", "VP8L"]
  @exif_header "Exif\0\0"

  @exif_flag 0x08
  @xmp_flag 0x04
  @alpha_flag 0x10

  @typedoc "Why a WebP is refused."
  @type reason :: :not_webp | :malformed | :malformed_exif

  @doc "The WebP with `changes` made (`Storehouse.MetadataEditor`): `:strip`, then `:put`."
  @spec edit(binary(), Storehouse.MetadataEditor.changes()) ::
          {:ok, binary()} | {:error, reason()}
  def edit(webp, changes) when is_binary(webp) and is_list(changes) do
    change = changer(changes)

    with {:ok, chunks, tail} <- parse(webp),
         {:ok, edited} <- Exif.safely(fn -> {:ok, change.(chunks)} end) do
      if edited == chunks,
        do: {:ok, webp},
        else: {:ok, IO.iodata_to_binary(encode(edited, tail))}
    end
  end

  @doc """
  The WebP at `from`, with `changes` made (as `edit/2`), written to `to`,
  with only its metadata in memory. `:unchanged` when there is nothing to
  change, and `to` is not written.
  """
  @spec edit_file(Path.t(), Path.t(), Storehouse.MetadataEditor.changes()) ::
          :ok | :unchanged | {:error, reason() | File.posix()}
  def edit_file(from, to, changes) when is_list(changes) do
    change = changer(changes)

    Container.open(from, &edit_into(&1, to, change))
  end

  defp edit_into(input, to, change) do
    with {:ok, chunks, tail} <- read(input),
         {:ok, edited} <- Exif.safely(fn -> {:ok, change.(chunks)} end) do
      if edited == chunks,
        do: :unchanged,
        else: Container.write(to, input, encode(edited, tail))
    end
  end

  @doc "The named tags its Exif has (`Storehouse.JPEG.tags/1`)."
  @spec tags(binary()) :: {:ok, map()} | {:error, reason()}
  def tags(webp) when is_binary(webp) do
    with {:ok, chunks, _tail} <- parse(webp) do
      Exif.safely(fn -> {:ok, Enum.find_value(chunks, %{}, &exif_tags/1)} end)
    end
  end

  defp exif_tags({"EXIF", data}), do: data |> tiff() |> elem(1) |> Exif.read()
  defp exif_tags(_chunk), do: nil

  # Chunks: `{fourcc, data}` for metadata, `{:raw, fourcc, part, head}`
  # for the rest, the whole chunk as it is or where it is in the file,
  # with its first bytes (an image's size is there).

  defp parse(<<"RIFF", size::little-32, "WEBP", rest::binary>>) when size >= 4 do
    body = min(size - 4, byte_size(rest))
    chunks(binary_part(rest, 0, body), [], binary_part(rest, body, byte_size(rest) - body))
  end

  defp parse(_other), do: {:error, :not_webp}

  defp chunks("", acc, tail), do: {:ok, Enum.reverse(acc), tail}

  defp chunks(<<fourcc::binary-4, size::little-32, rest::binary>> = chunk, acc, tail)
       when byte_size(rest) >= size do
    whole = min(8 + size + rem(size, 2), byte_size(chunk))
    data = binary_part(rest, 0, size)

    item =
      if fourcc in @metadata,
        do: {fourcc, data},
        else: {:raw, fourcc, binary_part(chunk, 0, whole), binary_part(data, 0, min(size, 16))}

    chunks(binary_part(chunk, whole, byte_size(chunk) - whole), [item | acc], tail)
  end

  defp chunks(_other, _acc, _tail), do: {:error, :malformed}

  defp read(io) do
    {:ok, file_size} = :file.position(io, :eof)
    {:ok, 0} = :file.position(io, 0)

    case :file.read(io, 12) do
      {:ok, <<"RIFF", size::little-32, "WEBP">>} when size >= 4 ->
        read_riff(io, min(8 + size, file_size), file_size)

      _other ->
        {:error, :not_webp}
    end
  end

  # The chunks up to the RIFF's end, and what the file has after it.
  defp read_riff(io, ends, file_size) do
    with {:ok, chunks} <- read_chunks(io, 12, ends, []),
         do: {:ok, chunks, if(ends < file_size, do: {ends, file_size - ends}, else: "")}
  end

  defp read_chunks(_io, at, ends, acc) when at >= ends, do: {:ok, Enum.reverse(acc)}

  defp read_chunks(io, at, ends, acc) do
    with {:ok, <<fourcc::binary-4, size::little-32>>} <- Container.read_exact(io, 8),
         true <- at + 8 + size <= ends,
         {:ok, item} <- read_chunk(io, at, fourcc, size, ends) do
      read_chunks(io, at + 8 + size + rem(size, 2), ends, [item | acc])
    else
      _short -> {:error, :malformed}
    end
  end

  defp read_chunk(io, at, fourcc, size, ends) do
    whole = min(8 + size + rem(size, 2), ends - at)

    with {:ok, data} <-
           Container.read_exact(io, if(fourcc in @metadata, do: size, else: min(size, 16))),
         :ok <- Container.skip(io, at, whole, ends) do
      if fourcc in @metadata,
        do: {:ok, {fourcc, data}},
        else: {:ok, {:raw, fourcc, {at, whole}, data}}
    end
  end

  defp encode(chunks, tail) do
    parts = Enum.map(chunks, &chunk/1)
    size = 4 + Enum.sum(Enum.map(chunks, &chunk_size/1))
    [<<"RIFF", size::little-32, "WEBP">>, parts, tail]
  end

  defp chunk({:raw, _fourcc, part, _head}), do: part

  defp chunk({fourcc, data}),
    do: [
      fourcc,
      <<byte_size(data)::little-32>>,
      data,
      :binary.copy(<<0>>, rem(byte_size(data), 2))
    ]

  defp chunk_size({:raw, _fourcc, {_at, size}, _head}), do: size
  defp chunk_size({:raw, _fourcc, bytes, _head}), do: byte_size(bytes)
  defp chunk_size({_fourcc, data}), do: 8 + byte_size(data) + rem(byte_size(data), 2)

  # The changes as one function of the chunks, then the header's flags
  # set by the chunks there are.
  defp changer(changes) do
    {strip, put} = Exif.changes!(changes, __MODULE__)

    fn chunks ->
      edited =
        case strip do
          nil -> chunks
          :gps -> Enum.map(chunks, &strip_gps/1)
          {:keep, codes, _tags} -> Enum.flat_map(chunks, &keep(&1, codes))
        end

      edited = if put, do: put_tags(edited, put), else: edited
      if edited == chunks, do: chunks, else: flagged(edited)
    end
  end

  # The Exif chunk's TIFF, and the header some writers put before it.
  defp tiff(@exif_header <> tiff), do: {@exif_header, tiff}
  defp tiff(tiff), do: {"", tiff}

  defp strip_gps({"EXIF", data}) do
    {header, tiff} = tiff(data)
    {"EXIF", header <> Exif.without_gps(tiff)}
  end

  defp strip_gps({"XMP ", xml}), do: {"XMP ", Exif.xmp_without_gps(xml)}
  defp strip_gps(chunk), do: chunk

  defp keep({"EXIF", data}, codes) do
    {header, tiff} = tiff(data)

    case Exif.kept(tiff, codes) do
      nil -> []
      tiff -> [{"EXIF", header <> tiff}]
    end
  end

  defp keep({:raw, fourcc, _part, _head} = chunk, _codes),
    do: if(fourcc in @image, do: [chunk], else: [])

  defp keep({"VP8X", _header} = chunk, _codes), do: [chunk]
  defp keep(_metadata, _codes), do: []

  defp put_tags(chunks, tags) do
    case Enum.find_index(chunks, &match?({"EXIF", _data}, &1)) do
      nil ->
        case Exif.put(nil, tags) do
          nil ->
            chunks

          tiff ->
            # After the image, before XMP.
            {before, xmp} = Enum.split_while(chunks, &(not match?({"XMP ", _xml}, &1)))
            before ++ [{"EXIF", tiff}] ++ xmp
        end

      index ->
        List.update_at(chunks, index, fn {"EXIF", data} ->
          {header, tiff} = tiff(data)
          {"EXIF", header <> Exif.put(tiff, tags)}
        end)
    end
  end

  # The VP8X header's Exif and XMP flags, as the chunks are; a simple
  # WebP with metadata now is given a header first.
  defp flagged(chunks) do
    exif = Enum.any?(chunks, &match?({"EXIF", _data}, &1))
    xmp = Enum.any?(chunks, &match?({"XMP ", _xml}, &1))

    case chunks do
      [{"VP8X", <<flags, rest::binary>>} | others] ->
        flags = flags |> band(bnot(@exif_flag ||| @xmp_flag)) |> bor(flag(exif, @exif_flag))
        [{"VP8X", <<bor(flags, flag(xmp, @xmp_flag)), rest::binary>>} | others]

      [{:raw, fourcc, _part, head} | _others] when exif or xmp ->
        {width, height, alpha} = canvas(fourcc, head)
        flags = flag(exif, @exif_flag) ||| flag(xmp, @xmp_flag) ||| flag(alpha, @alpha_flag)
        [{"VP8X", <<flags, 0::24, width - 1::little-24, height - 1::little-24>>} | chunks]

      chunks ->
        chunks
    end
  end

  defp flag(true, flag), do: flag
  defp flag(false, _flag), do: 0

  # The canvas of a simple WebP, from its image's own header.
  defp canvas(
         "VP8 ",
         <<_frame::binary-3, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _rest::binary>>
       ),
       do: {w &&& 0x3FFF, h &&& 0x3FFF, false}

  defp canvas("VP8L", <<0x2F, bits::little-32, _rest::binary>>),
    do: {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1, (bits >>> 28 &&& 1) == 1}

  defp canvas(_fourcc, _head), do: raise(ArgumentError, "no image to size a header from")
end
