defmodule Storehouse.Archive.Tar do
  @moduledoc """
  The tar format of `Storehouse.Archive`: for Unix tools and backups,
  gzipped (`.tar.gz`) or not, made as a stream.

    * `:compression` - `:auto` (the default) gzips the archive when most
      of its bytes shrink; `:compress` always, `:none` never.
    * Names longer than tar's own, or not ASCII, and files past 8 GB have
      a pax header (POSIX.1-2001), which every tar of this century reads.

  A tar's header gives a file's size before its bytes, so every file's
  size is known before: a file of unknown size (`{:stream, …}`,
  `{:call, …}`) gives an `ArgumentError`. It is not encrypted:
  `:password` gives one too.
  """

  @behaviour Storehouse.Archive.Format

  @block 512
  @max_octal 0o77777777777

  @impl true
  def content_type(entries, opts),
    do: if(gzip?(entries, opts), do: "application/gzip", else: "application/x-tar")

  @impl true
  def size(entries, opts) do
    cond do
      Enum.any?(entries, &is_nil(&1.size)) ->
        :unknown

      # gzip's header and end, and its stored blocks for what does not shrink.
      gzip?(entries, opts) ->
        {:about, total(entries) + 18 + 5 * (div(total(entries), 65_535) + 1)}

      true ->
        {:ok, total(entries)}
    end
  end

  @impl true
  def bound(entry, opts) do
    bytes = headers_size(entry) + padded(entry.size)
    if gzip?([entry], opts), do: bytes + div(bytes, 1_000) + 1_024, else: bytes
  end

  @impl true
  def end_bound(_count, _opts), do: 2 * @block + 1_024

  @impl true
  def stream(entries, opts) do
    if opts[:password],
      do: raise(ArgumentError, "a tar is not encrypted: give the zip format a :password")

    for entry <- entries,
        is_nil(entry.size),
        do:
          raise(
            ArgumentError,
            "#{entry.name}: a tar gives each file's size before it, and this one's is not known"
          )

    mtime = opts |> Keyword.get_lazy(:modified_at, &DateTime.utc_now/0) |> unix()

    tar =
      entries
      |> Stream.flat_map(fn entry ->
        Stream.concat([
          [headers(entry, mtime)],
          checked(entry),
          [padding(entry.size)]
        ])
      end)
      |> Stream.concat([:binary.copy(<<0>>, 2 * @block)])

    if gzip?(entries, opts), do: gzipped(tar), else: tar
  end

  # The file's bytes, its size checked at their end.
  defp checked(entry) do
    entry.data.()
    |> Stream.transform(
      fn -> 0 end,
      fn data, read -> {[data], read + IO.iodata_length(data)} end,
      fn read ->
        if read != entry.size,
          do: raise(ArgumentError, "#{entry.name} is #{read} bytes, not #{entry.size}")

        {[], read}
      end,
      fn _read -> :ok end
    )
  end

  defp gzip?(entries, opts) do
    case Keyword.get(opts, :compression, :auto) do
      :none -> false
      :compress -> true
      :auto -> compressible_bytes(entries) * 2 > Enum.sum(Enum.map(entries, &(&1.size || 0)))
    end
  end

  defp compressible_bytes(entries),
    do: entries |> Enum.filter(& &1.compress) |> Enum.map(&(&1.size || 0)) |> Enum.sum()

  defp gzipped(tar) do
    Stream.transform(
      tar,
      fn ->
        z = :zlib.open()
        :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
        z
      end,
      fn data, z -> {[:zlib.deflate(z, data)], z} end,
      fn z -> {[:zlib.deflate(z, [], :finish)], z} end,
      fn z -> :zlib.close(z) end
    )
  end

  # Sizes

  defp total(entries),
    do: Enum.reduce(entries, 2 * @block, &(headers_size(&1) + padded(&1.size) + &2))

  defp headers_size(entry),
    do: if(pax?(entry), do: @block + padded(byte_size(pax(entry))) + @block, else: @block)

  defp padded(size), do: div(size + @block - 1, @block) * @block

  defp padding(size) do
    case rem(size, @block) do
      0 -> ""
      left -> :binary.copy(<<0>>, @block - left)
    end
  end

  # Headers

  defp pax?(entry), do: ustar_name(entry.name) == nil or entry.size > @max_octal

  # A name tar's own fields hold: ASCII, up to 100 bytes, or a prefix of
  # up to 155 and a name of up to 100, split at a slash.
  defp ustar_name(name) do
    cond do
      not ascii?(name) -> nil
      byte_size(name) <= 100 -> {"", name}
      true -> split_name(name)
    end
  end

  defp ascii?(name), do: for(<<c <- name>>, reduce: true, do: (ok -> ok and c in 32..126))

  defp split_name(name) do
    parts = String.split(name, "/")

    Enum.find_value(1..(length(parts) - 1)//1, fn i ->
      {prefix, rest} = Enum.split(parts, i)
      {prefix, rest} = {Enum.join(prefix, "/"), Enum.join(rest, "/")}
      if byte_size(prefix) <= 155 and byte_size(rest) <= 100, do: {prefix, rest}
    end)
  end

  defp headers(entry, mtime) do
    if pax?(entry) do
      records = pax(entry)
      # The name tar's own field holds, for a tar of before pax: the pax
      # record's is the name.
      ascii = String.replace(entry.name, ~r/[^ -~]/u, "_")
      short = binary_part(ascii, 0, min(byte_size(ascii), 99))

      [
        header(
          "PaxHeaders/" <> binary_part(short, 0, min(byte_size(short), 88)),
          byte_size(records),
          mtime,
          "x"
        ),
        records,
        padding(byte_size(records)),
        header(short, min(entry.size, @max_octal), mtime, "0", {"", short})
      ]
    else
      header(entry.name, entry.size, mtime, "0", ustar_name(entry.name))
    end
  end

  # The pax records: the path, and the size past what tar holds.
  defp pax(entry) do
    records = [record("path", entry.name)]

    records =
      if entry.size > @max_octal,
        do: records ++ [record("size", Integer.to_string(entry.size))],
        else: records

    IO.iodata_to_binary(records)
  end

  # "<length> <key>=<value>\n", the length counting its own digits.
  defp record(key, value) do
    line = " #{key}=#{value}\n"
    length = byte_size(line) + digits(byte_size(line) + digits(byte_size(line)))
    "#{length}#{line}"
  end

  defp digits(n), do: n |> Integer.to_string() |> byte_size()

  defp header(name, size, mtime, type, split \\ nil) do
    {prefix, name} = split || {"", name}

    fields = [
      field(name, 100),
      octal(0o644, 8),
      octal(0, 8),
      octal(0, 8),
      octal(size, 12),
      octal(mtime, 12),
      "        ",
      type,
      field("", 100),
      "ustar\0",
      "00",
      field("", 32),
      field("", 32),
      octal(0, 8),
      octal(0, 8),
      field(prefix, 155),
      field("", 12)
    ]

    header = IO.iodata_to_binary(fields)
    sum = for(<<byte <- header>>, reduce: 0, do: (sum -> sum + byte))
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>
    <<before::binary-148, _blank::binary-8, rest::binary>> = header
    before <> checksum <> rest
  end

  defp field(text, size),
    do:
      binary_part(text, 0, min(byte_size(text), size)) <>
        :binary.copy(<<0>>, max(size - byte_size(text), 0))

  defp octal(n, size), do: String.pad_leading(Integer.to_string(n, 8), size - 1, "0") <> <<0>>

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  defp unix(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
