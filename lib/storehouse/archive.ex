defmodule Storehouse.Archive do
  @moduledoc """
  An archive of files, stored ones and the app's own, made as a stream: an
  export of an account's files, a folder to download, a backup. Nothing is
  written to the disk and no more than a chunk is in memory, however large
  the archive.

      entries = [
        {"README.txt", "Your photographs, as of 23 October 2026.\\n"}
        | for(photo <- photos, do: {"photos/" <> photo.name, {:stored, photo.key}})
      ]

      # Its size before it is made: "3.2 GB, 1,204 photographs".
      {:ok, bytes} = Storehouse.Archive.size(entries)

      # Into the store, out of the request, then the app's function with it.
      Storehouse.Archive.store_later(entries, "exports/42.zip",
        expires_in: 86_400,
        then: {MyApp.Exports, :ready, [account.id]}
      )

  ## Entries

  `{name, content}`, the name a path in the archive, the content one of:

    * `{:stored, key}` - a stored file, read a chunk at a time from
      `:adapter`, by the size the store gives.
    * a binary.
    * `{:call, {module, function, args}}` - a function that gives the
      content, a binary or an enumerable of iodata, called as the archive
      is made: what the app makes for it (a JSON of its records), and what
      a job can keep (`store_later/3`).
    * `{:stream, enumerable}` - iodata, as the archive is made.

  A name is a relative path of UTF-8, with no `..`, no backslash, and no
  leading `/`: the archive never puts a file outside the folder it is
  opened in. Two entries never have one name. A stored file must be the
  size it was when the archive began: one that changed stops it.

  ## Formats

  `:format` chooses it, else `config :storehouse, :archive_format`:

    * `:zip` (`Storehouse.Archive.Zip`, the default) - opened everywhere;
      compressed, encrypted with AES-256, past 4 GB (ZIP64).
    * `:tar` (`Storehouse.Archive.Tar`) - for Unix tools and backups, and
      gzipped (`.tar.gz`).
    * A module of the app's (`Storehouse.Archive.Format`).

  ## Compression

  `:compression` is `:auto` (the default): each file that shrinks is
  compressed (text, CSV, JSON, SVG, documents), and each that does not is
  stored as it is (photographs, video, audio, other archives, PDF). Both
  give the same bytes back, compression loses nothing: a photograph only
  takes ten to thirty times longer to compress, to save 1 to 3 %.
  `:compress` compresses every file; `:none`, none.

  ## Splitting

  `max_bytes:` makes several archives, each a whole one under the size,
  that each open alone (`export-1.zip`, `export-2.zip`, …): for a
  mailbox's limit, a FAT32 drive's 4 GB. A file larger than the size alone
  gives `{:error, {:too_large, name}}`.

  ## Out of the request

  Archiving 2 GB takes as long as reading 2 GB from the store and writing
  2 GB back: a minute or two, not a request's time. `store_later/3` makes it
  in a job of the app's runner (`Storehouse.Runner`: Oban's, kept through
  deploys and tried again), then calls the app's function with it.

  ## Telemetry

  `store/3` is a span, `[:storehouse, :archive, ...]`, with the `:key`,
  the `:format`, the number of `:entries`, and the `:bytes` made.
  """

  alias Storehouse.Archive.Entry
  alias Storehouse.Jobs.Archive, as: ArchiveJob

  @formats %{zip: Storehouse.Archive.Zip, tar: Storehouse.Archive.Tar}

  # Formats that do not shrink: compressed already.
  @stored_types ~w(image/jpeg image/png image/gif image/webp image/heic image/heif image/avif
                   video/mp4 video/webm application/pdf application/zip) ++
                  Enum.filter(
                    Storehouse.Check.types(),
                    &String.starts_with?(&1, "application/vnd.")
                  )
  @stored_extensions ~w(.jpg .jpeg .png .gif .webp .heic .heif .avif .mp4 .m4v .mov .webm .mkv
                        .avi .mp3 .m4a .aac .ogg .opus .flac .zip .gz .tgz .bz2 .xz .zst .7z .rar
                        .pdf .docx .xlsx .pptx .odt .ods .odp .epub)

  # A binary kept in a job's arguments, at most: larger ones go stored.
  @max_inline 1_048_576

  @typedoc "A file in the archive: its name, and its content."
  @type entry ::
          {String.t(),
           binary()
           | {:stored, Storehouse.Adapter.key()}
           | {:call, mfa()}
           | {:stream, Enumerable.t()}}

  @doc """
  The archive's size, before it is made, with the stored files' sizes
  asked of the store (not read):

    * `{:ok, bytes}` - exact, when nothing is compressed.
    * `{:about, bytes}` - with files compressed: the most it can be, its
      files' sizes as they are (a zip's or a tar's no larger).
    * `{:error, :unknown_size}` - with an entry of unknown size (a stream,
      a function).

  Takes `:adapter`, `:format`, `:compression` and `:password`.
  """
  @spec size([entry()], keyword()) ::
          {:ok, non_neg_integer()} | {:about, non_neg_integer()} | {:error, term()}
  def size(entries, opts \\ []) do
    with {:ok, format, opts} <- format(opts),
         {:ok, entries} <- resolved(entries, opts) do
      case format.size(entries, opts) do
        :unknown -> {:error, :unknown_size}
        size -> size
      end
    end
  end

  @doc """
  The archive as a stream of iodata, made as it is taken. Raises
  `Storehouse.ReadError` when the store fails halfway, and an
  `ArgumentError` when a file is not the size it was.

  Takes `:adapter`, `:format`, `:compression`, `:password` (with a format
  that encrypts), `:chunk_bytes` (as for `Storehouse.stream/2`) and
  `:modified_at`, the time each file is dated (the default is now).
  """
  @spec stream([entry()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(entries, opts \\ []) do
    with {:ok, format, opts} <- format(opts),
         {:ok, entries} <- resolved(entries, opts),
         do: {:ok, format.stream(entries, opts)}
  end

  @doc """
  The archive, written into the store under `key` as it is made
  (`c:Storehouse.Adapter.stream_open/2`: S3's multipart upload, a file on
  the disk): a `Storehouse.File`, with its size and checksum. With
  `:max_bytes`, a list of them, the parts' keys `key`'s with `-1`, `-2`, …
  before the extension.

  Takes the options of `stream/2`, and:

    * `:expires_in` - seconds after which it is deleted, under an expiring
      key (`Storehouse.expiring_key/2`): an export whose link lasts a day.
    * `:max_bytes` - the largest each archive is (see Splitting).

  A store's error, or a file not the size it was, gives `{:error, reason}`,
  and nothing is left in the store.
  """
  @spec store([entry()], Storehouse.Adapter.key(), keyword()) ::
          {:ok, Storehouse.File.t() | [Storehouse.File.t()]} | {:error, term()}
  def store(entries, key, opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    opts = Keyword.put(opts, :adapter, adapter)

    with {:ok, format, opts} <- format(opts),
         true <- Storehouse.valid_key?(key) || {:error, :invalid_key},
         {:ok, resolved} <- resolved(entries, opts) do
      case opts[:max_bytes] do
        nil -> store_one(format, resolved, key, opts)
        max -> store_parts(format, resolved, key, max, opts)
      end
    end
  end

  @doc """
  Makes the archive (`store/3`) out of the request, in a job of the app's
  runner (`Storehouse.Runner`), then calls the app's `:then` with
  `{:ok, file}` (or the list of parts): to email its link.

      Storehouse.Archive.store_later(entries, "exports/42.zip",
        expires_in: 86_400,
        then: {MyApp.Exports, :ready, [account.id]}
      )

  A job keeps what it is given, so its entries are what can be kept:
  `{:stored, key}`, `{:call, mfa}`, and binaries of up to 1 MB; not
  `{:stream, enumerable}`, which `{:call, mfa}` gives instead. A
  `:password` is never kept: give `{:call, mfa}`, a function that gives it
  in the job. A store that fails makes the job try again.

  Takes the options of `store/3`, `:then` (required), and `:runner`.
  """
  @spec store_later([entry()], Storehouse.Adapter.key(), keyword()) :: :ok | {:error, term()}
  def store_later(entries, key, opts) do
    {module, function, args} = Keyword.fetch!(opts, :then)
    true = is_atom(module) and is_atom(function) and is_list(args)
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)

    with {:ok, _format} <- format_module(opts) do
      kept =
        opts
        |> Keyword.take([:format, :compression, :max_bytes, :expires_in, :chunk_bytes, :then])
        |> Keyword.put(:adapter, adapter)
        |> Keyword.merge(kept_password(opts[:password]))

      entries
      |> Enum.map(&kept_entry/1)
      |> ArchiveJob.job(key, kept)
      |> Storehouse.Runner.enqueue(opts)
    end
  end

  defp kept_entry({name, {:stored, key}}) when is_binary(key), do: {name, {:stored, key}}

  defp kept_entry({_name, {:call, {m, f, a}}} = entry)
       when is_atom(m) and is_atom(f) and is_list(a), do: entry

  defp kept_entry({name, binary}) when is_binary(binary) do
    if byte_size(binary) <= @max_inline,
      do: {name, binary},
      else:
        raise(
          ArgumentError,
          "#{name} is too large to keep in a job: store it, and give {:stored, key}"
        )
  end

  defp kept_entry({name, {:stream, _enumerable}}),
    do:
      raise(
        ArgumentError,
        "#{name}: a stream cannot be kept in a job; give {:call, {module, function, args}}, which gives it"
      )

  defp kept_entry(entry), do: raise(ArgumentError, "not an archive's entry: #{inspect(entry)}")

  defp kept_password(nil), do: []

  defp kept_password({:call, {m, f, a}} = call) when is_atom(m) and is_atom(f) and is_list(a),
    do: [password: call]

  defp kept_password(_password),
    do:
      raise(
        ArgumentError,
        "a job never keeps a password: give {:call, {module, function, args}}, which gives it"
      )

  @doc false
  # The work of store_later/3, in its job.
  def store_now(entries, key, opts) do
    {module, function, args} = Keyword.fetch!(opts, :then)

    with {:ok, stored} <- store(entries, key, opts) do
      _result = apply(module, function, [{:ok, stored} | args])
      :ok
    end
  end

  defp password(nil), do: nil
  defp password({:call, {m, f, a}}), do: apply(m, f, a)
  defp password(password), do: password

  # The format, and the options it is given: the password, given now.
  defp format(opts) do
    with {:ok, module} <- format_module(opts),
         do: {:ok, module, Keyword.put(opts, :password, password(opts[:password]))}
  end

  defp format_module(opts) do
    format =
      Keyword.get_lazy(opts, :format, fn ->
        Application.get_env(:storehouse, :archive_format, :zip)
      end)

    module = Map.get(@formats, format, format)

    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :stream, 2),
      do: {:ok, module},
      else: {:error, {:unknown_format, format}}
  end

  # Entries

  # Each entry as a format takes it: its name, size (or nil), type,
  # whether to compress it, and its bytes as a function of nothing.
  defp resolved(entries, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    compression = Keyword.get(opts, :compression, :auto)

    with :ok <- names(entries) do
      entries
      |> Task.async_stream(&entry(&1, adapter, compression, opts),
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, entry}}, {:ok, acc} -> {:cont, {:ok, [entry | acc]}}
        {:ok, error}, _acc -> {:halt, error}
      end)
      |> then(fn
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end)
    end
  end

  defp entry({name, {:stored, key}}, adapter, compression, opts) do
    case Storehouse.head(key, adapter: adapter) do
      {:ok, %{bytes: bytes} = head} ->
        type = head.content_type || type_of(name)
        data = fn -> stored_data(name, key, bytes, adapter, opts) end
        {:ok, new(name, bytes, type, compression, data)}

      {:error, reason} ->
        {:error, {key, reason}}
    end
  end

  defp entry({name, binary}, _adapter, compression, _opts) when is_binary(binary),
    do: {:ok, new(name, byte_size(binary), type_of(name), compression, fn -> [binary] end)}

  defp entry({name, {:call, {m, f, a}}}, _adapter, compression, _opts)
       when is_atom(m) and is_atom(f) and is_list(a),
       do: {:ok, new(name, nil, type_of(name), compression, fn -> called(m, f, a) end)}

  defp entry({name, {:stream, enumerable}}, _adapter, compression, _opts),
    do: {:ok, new(name, nil, type_of(name), compression, fn -> enumerable end)}

  defp entry(entry, _adapter, _compression, _opts), do: {:error, {:invalid_entry, entry}}

  defp new(name, size, type, compression, data) do
    %Entry{
      name: name,
      size: size,
      content_type: type,
      compress: compress?(compression, name, type),
      data: data
    }
  end

  defp called(m, f, a) do
    case apply(m, f, a) do
      binary when is_binary(binary) -> [binary]
      enumerable -> enumerable
    end
  end

  defp type_of(name), do: Storehouse.Check.content_type(Path.extname(name))

  defp compress?(:none, _name, _type), do: false
  defp compress?(:compress, _name, _type), do: true

  defp compress?(:auto, name, type),
    do:
      type not in @stored_types and String.downcase(Path.extname(name)) not in @stored_extensions

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

  # A stored file, a chunk at a time, by its planned size: no second
  # question of its size to the store. The last read asks one byte past
  # it: a file that grew since gives it, and stops the archive. One that
  # shrank ends early, and the format's size check says so.
  defp stored_data(_name, _key, 0, _adapter, _opts), do: []

  defp stored_data(name, key, size, adapter, opts) do
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

  # Storing

  defp store_one(format, entries, key, opts) do
    key =
      if expires_in = opts[:expires_in], do: Storehouse.expiring_key(key, expires_in), else: key

    adapter = opts[:adapter]
    meta = %{key: key, adapter: adapter, format: format, entries: length(entries)}

    :telemetry.span([:storehouse, :archive], meta, fn ->
      result = stored(format, entries, key, adapter, opts)
      bytes = with {:ok, %Storehouse.File{bytes: bytes}} <- result, do: bytes
      {result, Map.merge(meta, %{result: result, bytes: bytes})}
    end)
  end

  defp store_parts(format, entries, key, max, opts) do
    with {:ok, parts} <- parts(format, entries, max, opts) do
      count = length(parts)

      parts
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, &store_part(format, key, count, opts, &1, &2))
      |> then(fn
        {:ok, files} -> {:ok, Enum.reverse(files)}
        error -> error
      end)
    end
  end

  defp store_part(format, key, count, opts, {part, i}, {:ok, done}) do
    case store_one(format, part, part_key(key, i, count), opts) do
      {:ok, file} -> {:cont, {:ok, [file | done]}}
      error -> {:halt, error}
    end
  end

  # Entries in parts, in their order, each part's bound under `max`.
  defp parts(format, entries, max, opts) do
    Enum.reduce_while(entries, {:ok, [], [], 0}, fn entry, {:ok, parts, part, used} ->
      bound = entry.size && format.bound(entry, opts)
      room = max - format.end_bound(length(part) + 1, opts)

      cond do
        is_nil(bound) -> {:halt, {:error, {:unknown_size, entry.name}}}
        bound > max - format.end_bound(1, opts) -> {:halt, {:error, {:too_large, entry.name}}}
        used + bound <= room -> {:cont, {:ok, parts, [entry | part], used + bound}}
        true -> {:cont, {:ok, [Enum.reverse(part) | parts], [entry], bound}}
      end
    end)
    |> case do
      {:ok, parts, [], _used} -> {:ok, Enum.reverse(parts)}
      {:ok, parts, part, _used} -> {:ok, Enum.reverse([Enum.reverse(part) | parts])}
      error -> error
    end
  end

  # `exports/42.zip` → `exports/42-1.zip`; one part keeps its key.
  defp part_key(key, _i, 1), do: key

  defp part_key(key, i, _count) do
    base = Path.basename(key)

    {stem, ext} =
      case String.split(base, ".", parts: 2) do
        [stem, ext] -> {stem, "." <> ext}
        [stem] -> {stem, ""}
      end

    dir = Path.dirname(key)
    name = "#{stem}-#{i}#{ext}"
    if dir == ".", do: name, else: dir <> "/" <> name
  end

  defp stored(format, entries, key, adapter, opts) do
    with true <- Storehouse.supports?(adapter, :stream_open, 2) || {:error, :not_supported},
         type = format.content_type(entries, opts),
         {:ok, upload} <- opened(adapter, key, type) do
      case written(format.stream(entries, opts), adapter, upload) do
        {:ok, upload, bytes, hash} -> closed(adapter, upload, key, bytes, hash, type)
        {:error, upload, reason} -> aborted(adapter, upload, reason)
      end
    end
  end

  # A store that opens no stream over a file there (the local disk) is
  # rid of it first: an archive made again takes its place.
  defp opened(adapter, key, type) do
    case adapter.stream_open(key, %{content_type: type}) do
      {:error, :eexist} ->
        with :ok <- adapter.delete(key), do: adapter.stream_open(key, %{content_type: type})

      opened ->
        opened
    end
  end

  defp written(archive, adapter, upload) do
    {upload, bytes, hash} =
      Enum.reduce(archive, {upload, 0, :crypto.hash_init(:sha256)}, fn data,
                                                                       {upload, bytes, hash} ->
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

  defp closed(adapter, upload, key, bytes, hash, type) do
    with {:ok, url} <- adapter.stream_close(upload) do
      {:ok,
       %Storehouse.File{
         key: key,
         url: url,
         name: Path.basename(key),
         content_type: type,
         bytes: bytes,
         checksum: hash |> :crypto.hash_final() |> Base.encode64()
       }}
    end
  end

  defp aborted(adapter, upload, reason) do
    adapter.stream_abort(upload)
    {:error, reason}
  end
end
