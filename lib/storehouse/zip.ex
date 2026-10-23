defmodule Storehouse.Zip do
  @moduledoc """
  A zip of files, stored ones and the app's own, made as a stream: an
  export of an account's files, a folder to download. Nothing is written
  to the disk and no more than a chunk is in memory, however large the
  zip, so a machine with little memory and less disk zips tens of GB.

      entries = [
        {"photos/harbour.jpg", {:stored, "2026/10/0b6…-harbour.jpg"}},
        {"README.txt", "Your photographs, as of 23 October 2026.\\n"},
        {"stories.jsonl", {:stream, Stream.map(stories, &MyApp.Exports.line/1)}}
      ]

      # The zip's size before it is made: "3.2 GB, 1,204 photographs".
      {:ok, bytes} = Storehouse.Zip.size(entries)

      # Into the store, a part at a time (S3's multipart upload).
      {:ok, file} = Storehouse.Zip.store(entries, "exports/42/2026-10-23.zip")

      # Or anywhere a stream of iodata goes: a response, a file.
      {:ok, stream} = Storehouse.Zip.stream(entries)

  ## Entries

  `{name, content}`, the name a path in the zip (`"photos/harbour.jpg"`)
  and the content one of:

    * `{:stored, key}` - a stored file, read a chunk at a time
      (`Storehouse.stream/2`) from `:adapter`.
    * a binary.
    * `{:stream, enumerable}` - iodata the app makes as the zip is made.
      Its size is not known before: `size/2` gives `{:error, :unknown_size}`.

  A name is a relative path of UTF-8, with no `..`, no backslash, and no
  leading `/`: the zip never puts a file outside the folder it is opened
  in. Two entries never have one name.

  ## The format

  Files are stored as they are (ZIP's STORE: photographs and videos do
  not compress), each followed by its CRC-32 in a data descriptor, with
  ZIP64 where a file, or the zip, passes 4 GB. A stored file must still
  be the size it was when the zip began: a file that changed in between
  stops the zip with an error.

  ## Telemetry

  `store/3` is a span, `[:storehouse, :zip, ...]`, with the `:key`, the
  number of `:entries` and the `:bytes`.
  """

  import Bitwise

  @limit 0xFFFFFFFF
  @version 20
  @version64 45
  # Bit 3: sizes and CRC in a data descriptor after the data; bit 11:
  # names in UTF-8.
  @flags 0x0808

  @typedoc "A file in the zip: its name, and its content."
  @type entry ::
          {String.t(), binary() | {:stored, Storehouse.Adapter.key()} | {:stream, Enumerable.t()}}

  @doc """
  The zip's exact size, in bytes, before it is made: the stored files'
  sizes are asked of the store (`Storehouse.head/2`), not read.
  `{:error, :unknown_size}` with an entry of `{:stream, enumerable}`.

  Takes `:adapter`.
  """
  @spec size([entry()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def size(entries, opts \\ []) do
    with {:ok, plan} <- plan(entries, opts),
         true <- Enum.all?(plan, &is_integer(&1.size)) || {:error, :unknown_size} do
      {:ok, total(plan)}
    end
  end

  @doc """
  The zip as a stream of iodata, made as it is taken: each stored file
  read a chunk at a time. Raises `Storehouse.ReadError` when the store
  fails halfway, and an `ArgumentError` when a file is not the size it
  was.

  Takes `:adapter`, `:chunk_bytes` (as for `Storehouse.stream/2`) and
  `:modified_at`, the time each file is dated (the default is now).
  """
  @spec stream([entry()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(entries, opts \\ []) do
    with {:ok, plan} <- plan(entries, opts) do
      {time, date} = dos_time(Keyword.get_lazy(opts, :modified_at, &NaiveDateTime.utc_now/0))
      {:ok, zip(plan, time, date, opts)}
    end
  end

  @doc """
  The zip, written into the store under `key` as it is made
  (`c:Storehouse.Adapter.stream_open/2`: S3's multipart upload, a file on
  the disk): a `Storehouse.File` of type `application/zip`, with its size
  and checksum.

  Takes the options of `stream/2`. A store's error, or a file not the
  size it was, gives `{:error, reason}`, and nothing is left in the store.
  """
  @spec store([entry()], Storehouse.Adapter.key(), keyword()) ::
          {:ok, Storehouse.File.t()} | {:error, term()}
  def store(entries, key, opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    meta = %{key: key, adapter: adapter, entries: length(entries)}

    :telemetry.span([:storehouse, :zip], meta, fn ->
      result = stored(entries, key, adapter, opts)
      bytes = with {:ok, %Storehouse.File{bytes: bytes}} <- result, do: bytes
      {result, Map.merge(meta, %{result: result, bytes: bytes})}
    end)
  end

  defp stored(entries, key, adapter, opts) do
    with true <- Storehouse.valid_key?(key) || {:error, :invalid_key},
         true <- Storehouse.supports?(adapter, :stream_open, 2) || {:error, :not_supported},
         {:ok, zip} <- stream(entries, Keyword.put(opts, :adapter, adapter)),
         {:ok, upload} <- adapter.stream_open(key, %{content_type: "application/zip"}) do
      case written(zip, adapter, upload) do
        {:ok, upload, bytes, hash} -> closed(adapter, upload, key, bytes, hash)
        {:error, upload, reason} -> aborted(adapter, upload, reason)
      end
    end
  end

  defp written(zip, adapter, upload) do
    {upload, bytes, hash} =
      Enum.reduce(zip, {upload, 0, :crypto.hash_init(:sha256)}, fn data, {upload, bytes, hash} ->
        case adapter.stream_write(upload, data) do
          {:ok, upload} ->
            {upload, bytes + IO.iodata_length(data), :crypto.hash_update(hash, data)}

          {:error, reason} ->
            throw({:write, upload, reason})
        end
      end)

    {:ok, upload, bytes, hash}
  rescue
    error in [Storehouse.ReadError] -> {:error, upload, error.reason}
    error in [ArgumentError] -> {:error, upload, Exception.message(error)}
  catch
    {:write, upload, reason} -> {:error, upload, reason}
  end

  defp closed(adapter, upload, key, bytes, hash) do
    with {:ok, url} <- adapter.stream_close(upload) do
      {:ok,
       %Storehouse.File{
         key: key,
         url: url,
         name: Path.basename(key),
         content_type: "application/zip",
         bytes: bytes,
         checksum: hash |> :crypto.hash_final() |> Base.encode64()
       }}
    end
  end

  defp aborted(adapter, upload, reason) do
    adapter.stream_abort(upload)
    {:error, reason}
  end

  # The plan: each entry's name, content, size (or nil), whether it is
  # ZIP64, and where its local header starts. The stream and size/2
  # follow it, so they never disagree.
  defp plan(entries, opts) do
    with :ok <- names(entries),
         {:ok, sized} <- sized(entries, opts) do
      {plan, _offset} =
        Enum.map_reduce(sized, 0, fn {name, content, size}, offset ->
          entry = %{name: name, content: content, size: size, zip64: zip64?(size), offset: offset}
          {entry, offset + local_size(entry) + (size || 0) + descriptor_size(entry)}
        end)

      {:ok, plan}
    end
  end

  defp names(entries) do
    Enum.reduce_while(entries, MapSet.new(), fn
      {name, _content}, seen when is_binary(name) ->
        cond do
          not safe_name?(name) -> {:halt, {:error, {:invalid_name, name}}}
          MapSet.member?(seen, name) -> {:halt, {:error, {:duplicate_name, name}}}
          true -> {:cont, MapSet.put(seen, name)}
        end

      other, _seen ->
        {:halt, {:error, {:invalid_entry, other}}}
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp safe_name?(name) do
    String.valid?(name) and byte_size(name) in 1..0xFFFF and not String.starts_with?(name, "/") and
      not String.contains?(name, ["\\", <<0>>]) and
      Enum.all?(String.split(name, "/"), &(&1 not in ["", ".", ".."]))
  end

  # Each entry's size: a stored file's from the store, a binary's own, a
  # stream's not known.
  defp sized(entries, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)

    entries
    |> Task.async_stream(&size_of(&1, adapter), max_concurrency: 8, timeout: :infinity)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, entry}}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
      {:ok, error}, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, sized} -> {:ok, Enum.reverse(sized)}
      error -> error
    end
  end

  defp size_of({name, {:stored, key} = content}, adapter) do
    case Storehouse.head(key, adapter: adapter) do
      {:ok, %{bytes: bytes}} -> {:ok, {name, content, bytes}}
      {:error, reason} -> {:error, {key, reason}}
    end
  end

  defp size_of({name, binary}, _adapter) when is_binary(binary),
    do: {:ok, {name, binary, byte_size(binary)}}

  defp size_of({name, {:stream, _enumerable} = content}, _adapter),
    do: {:ok, {name, content, nil}}

  defp size_of(entry, _adapter), do: {:error, {:invalid_entry, entry}}

  # A file of unknown size, or of 4 GB or more, is ZIP64.
  defp zip64?(nil), do: true
  defp zip64?(size), do: size >= @limit

  # Sizes

  defp local_size(entry), do: 30 + byte_size(entry.name) + if(entry.zip64, do: 20, else: 0)
  defp descriptor_size(entry), do: if(entry.zip64, do: 24, else: 16)

  defp central_size(entry), do: 46 + byte_size(entry.name) + byte_size(central_extra(entry, 0, 0))

  defp total(plan) do
    data =
      Enum.reduce(plan, 0, fn entry, sum ->
        sum + local_size(entry) + entry.size + descriptor_size(entry)
      end)

    central = Enum.reduce(plan, 0, &(central_size(&1) + &2))
    data + central + end_size(length(plan), data, central)
  end

  defp end_size(count, offset, central) do
    if zip64_end?(count, offset, central), do: 56 + 20 + 22, else: 22
  end

  defp zip64_end?(count, offset, central),
    do: count >= 0xFFFF or offset >= @limit or central >= @limit

  # The zip: each entry's header, data and descriptor as it is taken, and
  # the central directory at the end.

  defp zip(plan, time, date, opts) do
    plan
    |> Stream.flat_map(fn entry ->
      Stream.concat([
        [{:start, entry}],
        Stream.map(data(entry, opts), &{:data, &1}),
        [{:end, entry}]
      ])
    end)
    |> Stream.transform(
      fn -> %{crc: 0, bytes: 0, offset: 0, central: []} end,
      fn
        {:start, entry}, state ->
          {[local_header(entry, time, date)], %{state | crc: 0, bytes: 0}}

        {:data, data}, state ->
          {[data],
           %{
             state
             | crc: :erlang.crc32(state.crc, data),
               bytes: state.bytes + IO.iodata_length(data)
           }}

        {:end, entry}, state ->
          if entry.size && entry.size != state.bytes,
            do: raise(ArgumentError, "#{entry.name} is #{state.bytes} bytes, not #{entry.size}")

          if not entry.zip64 and state.bytes >= @limit,
            do: raise(ArgumentError, "#{entry.name} passed 4 GB")

          # Where it really starts: after a stream's, the plan cannot know.
          done = %{entry | size: state.bytes, offset: state.offset}

          {[descriptor(done, state.crc)],
           %{
             state
             | offset: state.offset + local_size(entry) + state.bytes + descriptor_size(entry),
               central: [{done, state.crc} | state.central]
           }}
      end,
      fn state ->
        {[central_directory(Enum.reverse(state.central), state.offset, time, date)], state}
      end,
      fn _state -> :ok end
    )
  end

  # A stored file, a chunk at a time, by its planned size: no second
  # question of its size to the store. The last read asks one byte past
  # it: a file that grew since gives it, and stops the zip. One that
  # shrank ends early, and the size check at its end says so.
  defp data(%{content: {:stored, _key}, size: 0}, _opts), do: []

  defp data(%{content: {:stored, key}, size: size, name: name}, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    chunk = Keyword.get(opts, :chunk_bytes, 4 * 1_048_576)

    Stream.unfold(0, fn
      :done ->
        nil

      offset ->
        last = min(offset + chunk, size + 1) - 1

        case adapter.read_range(key, offset, last) do
          {:ok, data} when offset + byte_size(data) > size ->
            raise ArgumentError, "#{name} is larger than its #{size} bytes"

          {:ok, ""} ->
            nil

          {:ok, data} ->
            {data, if(last >= size, do: :done, else: offset + byte_size(data))}

          {:error, reason} ->
            raise Storehouse.ReadError, key: key, reason: reason
        end
    end)
  end

  defp data(%{content: {:stream, enumerable}}, _opts), do: enumerable
  defp data(%{content: binary}, _opts) when is_binary(binary), do: [binary]

  defp local_header(entry, time, date) do
    {sizes, extra} =
      if entry.zip64,
        do:
          {<<@limit::little-32, @limit::little-32>>,
           <<0x0001::little-16, 16::little-16, 0::64, 0::64>>},
        else: {<<0::32, 0::32>>, ""}

    [
      <<0x04034B50::little-32, version(entry)::little-16, @flags::little-16, 0::little-16,
        time::little-16, date::little-16, 0::little-32>>,
      sizes,
      <<byte_size(entry.name)::little-16, byte_size(extra)::little-16>>,
      entry.name,
      extra
    ]
  end

  defp descriptor(entry, crc) do
    if entry.zip64,
      do: <<0x08074B50::little-32, crc::little-32, entry.size::little-64, entry.size::little-64>>,
      else:
        <<0x08074B50::little-32, crc::little-32, entry.size::little-32, entry.size::little-32>>
  end

  defp central_directory(entries, offset, time, date) do
    records = Enum.map(entries, fn {entry, crc} -> central_record(entry, crc, time, date) end)
    central = IO.iodata_length(records)
    [records, end_records(length(entries), offset, central)]
  end

  defp central_record(entry, crc, time, date) do
    big_size = entry.size >= @limit
    big_offset = entry.offset >= @limit
    extra = central_extra(entry, entry.size, entry.offset)

    [
      <<0x02014B50::little-32, 3 <<< 8 ||| @version64::little-16, version(entry)::little-16,
        @flags::little-16, 0::little-16, time::little-16, date::little-16, crc::little-32>>,
      <<if(big_size, do: @limit, else: entry.size)::little-32,
        if(big_size, do: @limit, else: entry.size)::little-32>>,
      <<byte_size(entry.name)::little-16, byte_size(extra)::little-16, 0::little-16, 0::little-16,
        0::little-16, 0o100644 <<< 16::little-32>>,
      <<if(big_offset, do: @limit, else: entry.offset)::little-32>>,
      entry.name,
      extra
    ]
  end

  # The central record's ZIP64 field, with only what passes 4 GB: the
  # sizes (both), then the offset. For size/2, the planned size decides.
  defp central_extra(entry, size, offset) do
    size = if entry.size, do: entry.size, else: size
    fields = if(size >= @limit, do: [<<size::little-64>>, <<size::little-64>>], else: [])
    offset = max(offset, entry.offset)
    fields = fields ++ if(offset >= @limit, do: [<<offset::little-64>>], else: [])

    case fields do
      [] ->
        ""

      fields ->
        IO.iodata_to_binary([<<0x0001::little-16, 8 * length(fields)::little-16>>, fields])
    end
  end

  defp end_records(count, offset, central) do
    eocd =
      if zip64_end?(count, offset, central),
        do:
          <<0x06054B50::little-32, 0::32, 0xFFFF::little-16, 0xFFFF::little-16, @limit::little-32,
            @limit::little-32, 0::16>>,
        else:
          <<0x06054B50::little-32, 0::32, count::little-16, count::little-16, central::little-32,
            offset::little-32, 0::16>>

    if zip64_end?(count, offset, central) do
      [
        <<0x06064B50::little-32, 44::little-64, 3 <<< 8 ||| @version64::little-16,
          @version64::little-16, 0::32, 0::32, count::little-64, count::little-64,
          central::little-64, offset::little-64>>,
        <<0x07064B50::little-32, 0::32, offset + central::little-64, 1::little-32>>,
        eocd
      ]
    else
      eocd
    end
  end

  defp version(entry), do: if(entry.zip64, do: @version64, else: @version)

  # MS-DOS time and date, as ZIP keeps them: two seconds at a time, from 1980.
  defp dos_time(%DateTime{} = at), do: at |> DateTime.to_naive() |> dos_time()

  defp dos_time(%NaiveDateTime{year: year} = at) when year < 1980,
    do: dos_time(%{at | year: 1980, month: 1, day: 1})

  defp dos_time(%NaiveDateTime{} = at) do
    time = at.hour <<< 11 ||| at.minute <<< 5 ||| div(at.second, 2)
    date = (at.year - 1980) <<< 9 ||| at.month <<< 5 ||| at.day
    {time, date}
  end
end
