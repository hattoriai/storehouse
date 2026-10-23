defmodule Storehouse.Archive.Zip do
  @moduledoc """
  The zip format of `Storehouse.Archive`, its default: opened by every
  system, as it is made, with nothing on the disk.

    * Each file is compressed (deflate) or stored as it is, as the
      archive's `:compression` says: by default, compressed where it
      shrinks.
    * With `:password`, each file is encrypted with AES-256 (WinZip's
      AE-2, a key of the password for each file, PBKDF2 and HMAC-SHA1):
      7-Zip, WinZip, Keka and The Unarchiver open it; macOS's Archive
      Utility and Windows' own zip folders do not. The files' names are
      not encrypted.
    * Past 4 GB a file, or 65,535 files, it is ZIP64.

  Each file is followed by its CRC-32 and sizes (a data descriptor), so
  nothing is read twice.
  """

  @behaviour Storehouse.Archive.Format

  import Bitwise

  alias Storehouse.Archive.AES

  @limit 0xFFFFFFFF
  # Bit 3: sizes and CRC in a data descriptor after the data; bit 11:
  # names in UTF-8; bit 0: encrypted.
  @flags 0x0808
  @aes_extra 11
  # Salt, password verifier, and the HMAC's first ten bytes.
  @aes_overhead 16 + 2 + 10
  # What deflate can add to bytes that do not shrink: 5 bytes every
  # 16 KB block, and its end.
  @deflate_margin 1_048_576

  @impl true
  def content_type(_entries, _opts), do: "application/zip"

  @impl true
  def size(entries, opts) do
    plan = plan(entries, opts)

    cond do
      Enum.any?(plan, &is_nil(&1.size)) -> :unknown
      Enum.any?(plan, & &1.deflate) -> {:about, total(plan)}
      true -> {:ok, total(plan)}
    end
  end

  @impl true
  def bound(entry, opts) do
    [planned] = plan([entry], opts)

    local_size(planned) + bound_data(planned) + descriptor_size(planned) + 46 +
      byte_size(planned.name) + 28 + if(planned.aes, do: @aes_extra, else: 0)
  end

  @impl true
  def end_bound(_count, _opts), do: 56 + 20 + 22

  @impl true
  def stream(entries, opts) do
    plan = plan(entries, opts)
    {time, date} = dos_time(Keyword.get_lazy(opts, :modified_at, &NaiveDateTime.utc_now/0))
    password = opts[:password]

    plan
    |> Stream.flat_map(fn entry ->
      Stream.concat([[{:start, entry}], Stream.map(entry.data.(), &{:data, &1}), [{:end, entry}]])
    end)
    |> Stream.transform(
      fn -> %{offset: 0, central: [], file: nil} end,
      fn
        {:start, entry}, state ->
          file = open_file(entry, password)
          {[local_header(entry, time, date), file.head], %{state | file: file}}

        {:data, data}, state ->
          {out, file} = written(state.file, data)
          {[out], %{state | file: file}}

        {:end, entry}, state ->
          {out, file} = finished(state.file)
          checked!(entry, file)

          # Where it really starts: after a file of unknown size, the plan
          # cannot know.
          done = %{entry | size: file.raw, offset: state.offset}
          descriptor = descriptor(done, file)

          {[out, descriptor],
           %{
             state
             | offset: state.offset + local_size(entry) + file.out + byte_size(descriptor),
               central: [{done, file} | state.central],
               file: nil
           }}
      end,
      fn state ->
        {[central_directory(Enum.reverse(state.central), state.offset, time, date)], state}
      end,
      fn state -> close_file(state.file) end
    )
  end

  defp checked!(entry, file) do
    if entry.size && entry.size != file.raw,
      do: raise(ArgumentError, "#{entry.name} is #{file.raw} bytes, not #{entry.size}")

    if not entry.zip64 and (file.raw >= @limit or file.out >= @limit),
      do: raise(ArgumentError, "#{entry.name} passed 4 GB")
  end

  # The plan: each file's method, encryption, whether it is ZIP64, and
  # where it starts when the sizes before it are known.
  defp plan(entries, opts) do
    aes = opts[:password] != nil

    {plan, _offset} =
      Enum.map_reduce(entries, 0, fn entry, offset ->
        deflate = entry.compress and entry.size != 0

        planned = %{
          name: entry.name,
          size: entry.size,
          data: entry.data,
          deflate: deflate,
          aes: aes,
          zip64: zip64?(entry.size, deflate, aes),
          offset: offset
        }

        {planned, offset + local_size(planned) + stored_data(planned) + descriptor_size(planned)}
      end)

    plan
  end

  defp zip64?(nil, _deflate, _aes), do: true

  defp zip64?(size, deflate, aes) do
    margin = if(deflate, do: div(size, 1_000) + @deflate_margin, else: 0)
    size + margin + if(aes, do: @aes_overhead, else: 0) >= @limit
  end

  # Sizes

  defp stored_data(%{size: nil}), do: 0
  defp stored_data(entry), do: entry.size + if(entry.aes, do: @aes_overhead, else: 0)

  # The most deflate adds to bytes that do not shrink: zlib falls back to
  # stored blocks, 5 bytes for each 64 KB, so `:about` is no less than the
  # zip made.
  defp most_added(%{deflate: true, size: size}), do: 5 * (div(size, 65_535) + 1)
  defp most_added(_entry), do: 0

  defp bound_data(entry) do
    stored_data(entry) + if(entry.deflate, do: div(entry.size, 1_000) + @deflate_margin, else: 0)
  end

  defp local_size(entry),
    do:
      30 + byte_size(entry.name) + if(entry.zip64, do: 20, else: 0) +
        if(entry.aes, do: @aes_extra, else: 0)

  defp descriptor_size(entry), do: if(entry.zip64, do: 24, else: 16)

  defp total(plan) do
    data =
      Enum.reduce(
        plan,
        0,
        &(local_size(&1) + stored_data(&1) + most_added(&1) + descriptor_size(&1) + &2)
      )

    central =
      Enum.reduce(plan, 0, fn entry, sum ->
        out = stored_data(entry)

        sum + 46 + byte_size(entry.name) +
          byte_size(central_extra(entry, entry.size, out, entry.offset)) +
          byte_size(aes_extra(entry))
      end)

    data + central + end_size(length(plan), data, central)
  end

  defp end_size(count, offset, central),
    do: if(zip64_end?(count, offset, central), do: 56 + 20 + 22, else: 22)

  defp zip64_end?(count, offset, central),
    do: count >= 0xFFFF or offset >= @limit or central >= @limit

  # A file's bytes: CRC-32 of them as they are, deflated, encrypted.

  defp open_file(entry, password) do
    z = if entry.deflate, do: deflater()
    file = %{crc: 0, raw: 0, out: 0, z: z, aes: nil, head: ""}

    if password do
      {head, aes} = AES.open(password)
      %{file | aes: aes, head: head, out: byte_size(head)}
    else
      file
    end
  end

  defp deflater do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    z
  end

  defp written(file, data) do
    file = %{file | crc: :erlang.crc32(file.crc, data), raw: file.raw + IO.iodata_length(data)}
    data = if file.z, do: :zlib.deflate(file.z, data), else: data
    encrypted(file, data)
  end

  defp finished(file) do
    tail =
      if file.z do
        tail = :zlib.deflate(file.z, [], :finish)
        :ok = :zlib.deflateEnd(file.z)
        :zlib.close(file.z)
        tail
      else
        []
      end

    {out, file} = encrypted(%{file | z: nil}, tail)

    if file.aes do
      mac = AES.mac(file.aes)
      {[out, mac], %{file | out: file.out + byte_size(mac)}}
    else
      {out, file}
    end
  end

  defp encrypted(%{aes: nil} = file, data),
    do: {data, %{file | out: file.out + IO.iodata_length(data)}}

  defp encrypted(file, data) do
    {out, aes} = AES.encrypt(file.aes, data)
    {out, %{file | aes: aes, out: file.out + byte_size(out)}}
  end

  defp close_file(%{z: z}) when z != nil, do: :zlib.close(z)
  defp close_file(_file), do: :ok

  # Headers

  defp method(%{aes: true}), do: 99
  defp method(%{deflate: true}), do: 8
  defp method(_entry), do: 0

  defp version(%{aes: true}), do: 51
  defp version(%{zip64: true}), do: 45
  defp version(_entry), do: 20

  defp flags(%{aes: true}), do: @flags ||| 1
  defp flags(_entry), do: @flags

  # AE-2: the CRC is not written, the HMAC stands for it.
  defp crc(%{aes: true}, _file), do: 0
  defp crc(_entry, file), do: file.crc

  defp aes_extra(%{aes: true} = entry) do
    actual = if entry.deflate, do: 8, else: 0
    <<0x9901::little-16, 7::little-16, 2::little-16, "AE", 3, actual::little-16>>
  end

  defp aes_extra(_entry), do: ""

  defp local_header(entry, time, date) do
    {sizes, zip64} =
      if entry.zip64,
        do:
          {<<@limit::little-32, @limit::little-32>>,
           <<0x0001::little-16, 16::little-16, 0::64, 0::64>>},
        else: {<<0::32, 0::32>>, ""}

    extra = zip64 <> aes_extra(entry)

    [
      <<0x04034B50::little-32, version(entry)::little-16, flags(entry)::little-16,
        method(entry)::little-16, time::little-16, date::little-16, 0::little-32>>,
      sizes,
      <<byte_size(entry.name)::little-16, byte_size(extra)::little-16>>,
      entry.name,
      extra
    ]
  end

  defp descriptor(entry, file) do
    crc = crc(entry, file)

    if entry.zip64,
      do: <<0x08074B50::little-32, crc::little-32, file.out::little-64, file.raw::little-64>>,
      else: <<0x08074B50::little-32, crc::little-32, file.out::little-32, file.raw::little-32>>
  end

  defp central_directory(entries, offset, time, date) do
    records = Enum.map(entries, fn {entry, file} -> central_record(entry, file, time, date) end)
    central = IO.iodata_length(records)
    [records, end_records(length(entries), offset, central)]
  end

  defp central_record(entry, file, time, date) do
    extra = central_extra(entry, file.raw, file.out, entry.offset) <> aes_extra(entry)

    [
      <<0x02014B50::little-32, 3 <<< 8 ||| 45::little-16, version(entry)::little-16,
        flags(entry)::little-16, method(entry)::little-16, time::little-16, date::little-16,
        crc(entry, file)::little-32>>,
      <<min(file.out, @limit)::little-32, min(file.raw, @limit)::little-32>>,
      <<byte_size(entry.name)::little-16, byte_size(extra)::little-16, 0::little-16, 0::little-16,
        0::little-16, 0o100644 <<< 16::little-32>>,
      <<min(entry.offset, @limit)::little-32>>,
      entry.name,
      extra
    ]
  end

  # The central record's ZIP64 field, with what passes 4 GB, in its
  # order: the size, the compressed size, the offset.
  defp central_extra(_entry, raw, out, offset) do
    fields =
      [{raw, raw >= @limit}, {out, out >= @limit}, {offset, offset >= @limit}]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&<<elem(&1, 0)::little-64>>)

    case fields do
      [] ->
        ""

      fields ->
        IO.iodata_to_binary([<<0x0001::little-16, 8 * length(fields)::little-16>>, fields])
    end
  end

  defp end_records(count, offset, central) do
    if zip64_end?(count, offset, central) do
      [
        <<0x06064B50::little-32, 44::little-64, 3 <<< 8 ||| 45::little-16, 45::little-16, 0::32,
          0::32, count::little-64, count::little-64, central::little-64, offset::little-64>>,
        <<0x07064B50::little-32, 0::32, offset + central::little-64, 1::little-32>>,
        <<0x06054B50::little-32, 0::32, 0xFFFF::little-16, 0xFFFF::little-16, @limit::little-32,
          @limit::little-32, 0::16>>
      ]
    else
      <<0x06054B50::little-32, 0::32, count::little-16, count::little-16, central::little-32,
        offset::little-32, 0::16>>
    end
  end

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
