defmodule Storehouse.Image.PNG do
  @moduledoc """
  Edits the metadata inside a PNG without re-encoding it, as
  `Storehouse.Image.JPEG` does a JPEG's: the same changes, the same tags.

  A PNG keeps its metadata in chunks of their own: Exif (`eXIf`), XMP and
  text (`iTXt`, `tEXt`, `zTXt`), the time (`tIME`). These functions
  rewrite those chunks, each with its checksum, and copy every other one,
  the image data and what draws it (palette, transparency, colour
  profile, an APNG's frames), byte for byte.

    * `strip: :gps` - the Exif GPS directory, zeroed, and XMP's GPS
      properties. The "Raw profile type" text chunks ImageMagick writes,
      Exif and XMP again in hexadecimal, go too.
    * `strip: {:keep, tags}` - Exif with only the tags named, the text
      chunks of those tags (`Author`, `Copyright`, `Description`), and no
      other text, XMP or time.
    * `put: %{artist: _, copyright: _, image_description: _}` - written
      into Exif, and as the text chunks `Author`, `Copyright` and
      `Description` that PNG readers show, in place of any before them.

  `edit_file/3` reads only the metadata chunks into memory. A PNG whose
  chunks cannot be read is refused with `{:error, :malformed}`, one whose
  Exif cannot be read with `{:error, :malformed_exif}`.
  """

  alias Storehouse.Image.{Container, Exif}

  @signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  # The chunks read into memory: metadata. Every other one is copied.
  @metadata ~w(eXIf tEXt zTXt iTXt tIME)
  @text ~w(tEXt zTXt iTXt)
  @xmp "XML:com.adobe.xmp"
  @keywords %{artist: "Author", copyright: "Copyright", image_description: "Description"}

  # Text inflated to no more than this, so a small chunk cannot fill memory.
  @max_text 16_777_216

  @typedoc "Why a PNG is refused."
  @type reason :: :not_png | :malformed | :malformed_exif

  @doc "The PNG with `changes` made (`Storehouse.Image.MetadataEditor`): `:strip`, then `:put`."
  @spec edit(binary(), Storehouse.Image.MetadataEditor.changes()) ::
          {:ok, binary()} | {:error, reason()}
  def edit(png, changes) when is_binary(png) and is_list(changes) do
    change = changer(changes)

    with {:ok, chunks, tail} <- parse(png),
         {:ok, edited} <- Exif.safely(fn -> {:ok, change.(chunks)} end) do
      if edited == chunks,
        do: {:ok, png},
        else: {:ok, IO.iodata_to_binary(encode(edited, tail))}
    end
  end

  @doc """
  The PNG at `from`, with `changes` made (as `edit/2`), written to `to`,
  with only its metadata in memory. `:unchanged` when there is nothing to
  change, and `to` is not written.
  """
  @spec edit_file(Path.t(), Path.t(), Storehouse.Image.MetadataEditor.changes()) ::
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

  @doc """
  The named tags its Exif has (`Storehouse.Image.JPEG.tags/1`), and the text
  chunks `Author`, `Copyright` and `Description` as `:artist`,
  `:copyright` and `:image_description` where Exif has none.
  """
  @spec tags(binary()) :: {:ok, map()} | {:error, reason()}
  def tags(png) when is_binary(png) do
    with {:ok, chunks, _tail} <- parse(png) do
      Exif.safely(fn -> {:ok, Map.merge(text_tags(chunks), exif_tags(chunks))} end)
    end
  end

  defp exif_tags(chunks), do: chunks |> Enum.find_value(%{}, &exif_tags_of/1)

  defp exif_tags_of({"eXIf", tiff}), do: Exif.read(tiff)
  defp exif_tags_of(_chunk), do: nil

  defp text_tags(chunks) do
    for {type, data} <- chunks,
        type in @text,
        {tag, keyword} <- @keywords,
        keyword(data) == keyword,
        {:ok, value} <- [text(type, data)],
        into: %{},
        do: {tag, value}
  end

  # Chunks: `{type, data}` for metadata, `{:raw, type, part}` for the
  # rest, the whole chunk as it is, or where it is in the file.

  defp parse(<<@signature, rest::binary>>), do: chunks(rest, [])
  defp parse(_other), do: {:error, :not_png}

  defp chunks(<<size::32, type::binary-4, rest::binary>> = chunk, acc)
       when byte_size(rest) >= size + 4 do
    next = binary_part(chunk, 12 + size, byte_size(chunk) - 12 - size)

    item =
      if type in @metadata,
        do: {type, binary_part(rest, 0, size)},
        else: {:raw, type, binary_part(chunk, 0, 12 + size)}

    if type == "IEND",
      do: {:ok, Enum.reverse([item | acc]), next},
      else: chunks(next, [item | acc])
  end

  defp chunks(_other, _acc), do: {:error, :malformed}

  defp read(io) do
    {:ok, size} = :file.position(io, :eof)
    {:ok, 0} = :file.position(io, 0)

    case :file.read(io, 8) do
      {:ok, @signature} -> read_chunks(io, 8, size, [])
      _other -> {:error, :not_png}
    end
  end

  defp read_chunks(io, at, file_size, acc) do
    with {:ok, <<size::32, type::binary-4>>} <- Container.read_exact(io, 8),
         {:ok, item} <- read_chunk(io, at, type, size, file_size) do
      after_chunk(io, type, at + 12 + size, file_size, [item | acc])
    else
      _short -> {:error, :malformed}
    end
  end

  # After IEND, what the file has left is kept as it is.
  defp after_chunk(_io, "IEND", next, file_size, acc),
    do: {:ok, Enum.reverse(acc), if(next < file_size, do: {next, file_size - next}, else: "")}

  defp after_chunk(io, _type, next, file_size, acc), do: read_chunks(io, next, file_size, acc)

  defp read_chunk(io, _at, type, size, _file_size) when type in @metadata do
    with {:ok, <<data::binary-size(^size), _crc::binary-4>>} <- Container.read_exact(io, size + 4),
         do: {:ok, {type, data}}
  end

  defp read_chunk(io, at, type, size, file_size) do
    with :ok <- Container.skip(io, at + 8, size + 4, file_size),
         do: {:ok, {:raw, type, {at, 12 + size}}}
  end

  defp encode(chunks, tail), do: [@signature, Enum.map(chunks, &chunk/1), tail]

  defp chunk({:raw, _type, part}), do: part

  defp chunk({type, data}),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  # The changes as one function of the chunks.
  defp changer(changes) do
    {strip, put} = Exif.changes!(changes, __MODULE__)

    fn chunks ->
      chunks =
        case strip do
          nil -> chunks
          :gps -> Enum.flat_map(chunks, &strip_gps/1)
          {:keep, codes, tags} -> Enum.flat_map(chunks, &keep(&1, codes, keywords(tags)))
        end

      if put, do: put_tags(chunks, put), else: chunks
    end
  end

  defp keywords(tags), do: for(tag <- tags, keyword = @keywords[tag], do: keyword)

  # strip(:gps)

  defp strip_gps({"eXIf", tiff}), do: [{"eXIf", Exif.without_gps(tiff)}]

  defp strip_gps({type, data} = chunk) when type in @text do
    case keyword(data) do
      @xmp -> [{type, map_text(type, data, &Exif.xmp_without_gps/1)}]
      "Raw profile type " <> profile when profile in ["exif", "APP1", "xmp"] -> []
      _other -> [chunk]
    end
  end

  defp strip_gps(chunk), do: [chunk]

  # strip({:keep, tags})

  defp keep({"eXIf", tiff}, codes, _keywords) do
    case Exif.kept(tiff, codes) do
      nil -> []
      tiff -> [{"eXIf", tiff}]
    end
  end

  defp keep({type, data} = chunk, _codes, keywords) when type in @text,
    do: if(keyword(data) in keywords, do: [chunk], else: [])

  defp keep({"tIME", _time}, _codes, _keywords), do: []
  defp keep(chunk, _codes, _keywords), do: [chunk]

  # put

  defp put_tags(chunks, tags) do
    replaced = for {tag, _value} <- tags, do: @keywords[tag]

    chunks =
      Enum.reject(chunks, fn
        {type, data} when type in @text -> keyword(data) in replaced
        _chunk -> false
      end)

    texts = for {tag, value} <- tags, value != nil, do: {"iTXt", itxt(@keywords[tag], value)}

    {chunks, exif} =
      case Enum.find_index(chunks, &match?({"eXIf", _tiff}, &1)) do
        nil ->
          {chunks, Exif.put(nil, tags)}

        index ->
          {List.update_at(chunks, index, fn {"eXIf", tiff} -> {"eXIf", Exif.put(tiff, tags)} end),
           nil}
      end

    added = if(exif, do: [{"eXIf", exif}], else: []) ++ texts
    {before, image} = Enum.split_while(chunks, &(not image?(&1)))
    before ++ added ++ image
  end

  # New chunks go before the image data, as Exif must.
  defp image?({:raw, type, _part}), do: type in ["IDAT", "fdAT", "IEND"]
  defp image?(_chunk), do: false

  defp itxt(keyword, value), do: keyword <> <<0, 0, 0>> <> <<0, 0>> <> value

  # Text chunks: a keyword, then the text, as each type keeps it.

  defp keyword(data), do: data |> :binary.split(<<0>>) |> hd()

  defp text("tEXt", data) do
    [_keyword, text] = :binary.split(data, <<0>>)
    {:ok, :unicode.characters_to_binary(text, :latin1)}
  end

  defp text("zTXt", data) do
    [_keyword, <<0, compressed::binary>>] = :binary.split(data, <<0>>)

    with {:ok, text} <- inflate(compressed),
         do: {:ok, :unicode.characters_to_binary(text, :latin1)}
  end

  defp text("iTXt", data) do
    [_keyword, <<compressed, 0, rest::binary>>] = :binary.split(data, <<0>>)
    [_language, rest] = :binary.split(rest, <<0>>)
    [_translated, text] = :binary.split(rest, <<0>>)
    if compressed == 1, do: inflate(text), else: {:ok, text}
  end

  # An XMP's text, edited, kept as its chunk kept it.
  defp map_text("iTXt", data, fun) do
    [keyword, <<compressed, 0, rest::binary>>] = :binary.split(data, <<0>>)
    [language, rest] = :binary.split(rest, <<0>>)
    [translated, text] = :binary.split(rest, <<0>>)
    {:ok, text} = if compressed == 1, do: inflate(text), else: {:ok, text}
    text = fun.(text)
    text = if compressed == 1, do: :zlib.compress(text), else: text
    IO.iodata_to_binary([keyword, 0, compressed, 0, language, 0, translated, 0, text])
  end

  defp map_text(type, data, fun) do
    [keyword, text] = :binary.split(data, <<0>>)

    case type do
      "tEXt" ->
        keyword <> <<0>> <> fun.(text)

      "zTXt" ->
        <<0, compressed::binary>> = text
        {:ok, text} = inflate(compressed)
        keyword <> <<0, 0>> <> :zlib.compress(fun.(text))
    end
  end

  # zlib, inflated a part at a time, refused past `@max_text`; what zlib
  # cannot inflate raises as a TIFF that cannot be read does.
  defp inflate(compressed) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflated(z, :zlib.safeInflate(z, compressed), [], 0)
    rescue
      error in ErlangError ->
        reraise ArgumentError, [message: Exception.message(error)], __STACKTRACE__
    after
      :zlib.close(z)
    end
  end

  defp inflated(_z, _result, _acc, size) when size > @max_text,
    do: raise(ArgumentError, "too large")

  defp inflated(z, {:continue, output}, acc, size),
    do: inflated(z, :zlib.safeInflate(z, []), [acc | output], size + IO.iodata_length(output))

  defp inflated(_z, {:finished, output}, acc, size) do
    if size + IO.iodata_length(output) > @max_text,
      do: raise(ArgumentError, "too large"),
      else: {:ok, IO.iodata_to_binary([acc | output])}
  end
end
