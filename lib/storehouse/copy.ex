defmodule Storehouse.Copy do
  @moduledoc false
  # Copies between two stores (`Storehouse.copy/2`, `Storehouse.copy_prefix/2`):
  # in the store itself when both are buckets the same credentials reach,
  # or folders of this disk; else a chunk at a time, through the app, its
  # checksum checked on the way.

  alias Storehouse.Check

  # The largest file S3 copies in one CopyObject.
  @s3_copy_limit 5 * 1024 * 1024 * 1024

  @doc false
  def copy(key, opts) do
    {from, to} = stores!(opts)
    meta = %{key: key, from: from, to: to}

    :telemetry.span([:storehouse, :copy], meta, fn ->
      result = do_copy(key, from, to, opts)
      {result, Map.put(meta, :result, result)}
    end)
  end

  @doc false
  def copy_prefix(prefix, opts) do
    {from, to} = stores!(opts)
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    progress = Keyword.get(opts, :on_progress, fn _key, _result -> :ok end)
    meta = %{prefix: prefix, from: from, to: to}

    :telemetry.span([:storehouse, :copy_prefix], meta, fn ->
      result =
        with {:ok, entries} <- listed(prefix, from) do
          copy_all(entries, opts, concurrency, progress)
        end

      {result, Map.put(meta, :result, result)}
    end)
  end

  # Every file for `""`, which `Storehouse.list/2` refuses so that no
  # deletion takes them all.
  defp listed("", from) do
    if Code.ensure_loaded?(from) and function_exported?(from, :list, 1) do
      with {:ok, entries} <- from.list(""),
           do: {:ok, Stream.filter(entries, &Storehouse.valid_key?(&1.key))}
    else
      {:error, :not_supported}
    end
  end

  defp listed(prefix, from), do: Storehouse.list(prefix, adapter: from)

  defp stores!(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    if from == to,
      do: raise(ArgumentError, "a copy is from one store to another, got #{inspect(from)} twice")

    {from, to}
  end

  defp copy_all(entries, opts, concurrency, progress) do
    summary =
      entries
      |> Task.async_stream(&{&1.key, copy(&1.key, opts)},
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(%{copied: 0, skipped: 0, failed: []}, fn {:ok, {key, result}}, summary ->
        progress.(key, result)
        counted(summary, key, result)
      end)

    {:ok, %{summary | failed: Enum.reverse(summary.failed)}}
  rescue
    # The source's list, failing a page in.
    error in Storehouse.ReadError -> {:error, error.reason}
  end

  defp counted(summary, _key, {:ok, :copied}), do: %{summary | copied: summary.copied + 1}
  defp counted(summary, _key, {:ok, :skipped}), do: %{summary | skipped: summary.skipped + 1}

  defp counted(summary, key, {:error, reason}),
    do: %{summary | failed: [{key, reason} | summary.failed]}

  defp do_copy(key, from, to, opts) do
    with true <- Storehouse.valid_key?(key) || {:error, :invalid_key},
         {:ok, source} <- Storehouse.head(key, adapter: from) do
      key |> there(to, source, from, opts) |> copied(key, from, to, source)
    end
  end

  defp copied(:same, _key, _from, _to, _source), do: {:ok, :skipped}

  defp copied({:copy, exists}, key, from, to, source) do
    with :ok <- write(key, from, to, source, exists), do: {:ok, :copied}
  end

  defp copied({:error, reason}, _key, _from, _to, _source), do: {:error, reason}

  # Whether the destination has the file already: the same size, and the
  # same checksum when both stores keep a whole file's (S3's of a file
  # sent in parts is of its parts' instead), or, with `:verify`, both
  # read to compare.
  defp there(key, to, source, from, opts) do
    case Storehouse.head(key, adapter: to) do
      {:ok, %{bytes: bytes} = copy} when bytes == source.bytes ->
        if same?(key, source, copy, from, to, opts), do: :same, else: {:copy, true}

      {:ok, _other} ->
        {:copy, true}

      {:error, reason} when reason in [:enoent, :not_supported] ->
        {:copy, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same?(key, source, copy, from, to, opts) do
    cond do
      whole?(source.checksum) and whole?(copy.checksum) -> source.checksum == copy.checksum
      opts[:verify] -> read_checksum(key, from, source) == read_checksum(key, to, copy)
      true -> true
    end
  end

  # A checksum of the whole file, as `Storehouse.checksum/1` gives one: not
  # S3's of a file's parts (`…-3`).
  defp whole?(checksum), do: is_binary(checksum) and not String.contains?(checksum, "-")

  defp read_checksum(key, store, head) do
    if whole?(head.checksum) do
      head.checksum
    else
      with {:ok, chunks} <- Storehouse.stream(key, adapter: store) do
        chunks
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode64()
      end
    end
  end

  defp write(key, from, to, source, exists) do
    case in_store(from, to, source) do
      {store, from_c, to_c} -> store.copy_between(from_c, key, to_c, key)
      nil -> streamed(key, from, to, source, exists)
    end
  end

  # Both buckets reached by the same credentials, or both folders of this
  # disk: the store copies it.
  defp in_store(from, to, source) do
    case {store_of(from), store_of(to)} do
      {{Storehouse.S3, from_c}, {Storehouse.S3, to_c}} ->
        if Storehouse.S3.same_account?(from_c, to_c) and source.bytes <= @s3_copy_limit,
          do: {Storehouse.S3, from_c, to_c}

      {{Storehouse.Local, from_c}, {Storehouse.Local, to_c}} ->
        {Storehouse.Local, from_c, to_c}

      _other ->
        nil
    end
  end

  defp store_of(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :__store__, 0),
      do: store.__store__()
  end

  # A chunk at a time from one store into the other, and its checksum,
  # computed on the way, compared with the source's before the copy is
  # kept.
  defp streamed(key, from, to, source, exists) do
    meta = %{
      content_type: source.content_type || Check.content_type(Path.extname(key)),
      bytes: source.bytes
    }

    meta = if whole?(source.checksum), do: Map.put(meta, :checksum, source.checksum), else: meta

    streams? = Code.ensure_loaded?(to) and function_exported?(to, :stream_open, 2)

    with {:ok, chunks} <- Storehouse.stream(key, adapter: from) do
      chunks
      |> then(&if(streams?, do: stream_into(key, &1, to, meta, exists), else: :no_stream))
      |> or_through_file(key, from, to, meta)
    end
  end

  # A store that takes no stream (or a mirror whose primary takes none):
  # through a temporary file.
  defp or_through_file(result, key, from, to, meta)
       when result in [:no_stream, {:error, :not_supported}],
       do: through_file(key, from, to, meta)

  defp or_through_file(result, _key, _from, _to, _meta), do: result

  defp stream_into(key, chunks, to, meta, exists) do
    # A store that opens no stream over a file (the local disk) is given
    # none.
    with :ok <- if(exists, do: to.delete(key), else: :ok),
         {:ok, stream} <- to.stream_open(key, meta) do
      case written(chunks, to, stream) do
        {:ok, stream, checksum} -> closed(to, stream, checksum, meta)
        {:error, stream, reason} -> aborted(to, stream, reason)
      end
    end
  end

  defp written(chunks, to, stream) do
    {stream, hash} =
      Enum.reduce(chunks, {stream, :crypto.hash_init(:sha256)}, fn chunk, {stream, hash} ->
        case to.stream_write(stream, chunk) do
          {:ok, stream} -> {stream, :crypto.hash_update(hash, chunk)}
          {:error, reason} -> throw({:write, stream, reason})
        end
      end)

    {:ok, stream, hash |> :crypto.hash_final() |> Base.encode64()}
  rescue
    error in Storehouse.ReadError -> {:error, stream, error.reason}
  catch
    {:write, stream, reason} -> {:error, stream, reason}
  end

  defp closed(to, stream, checksum, meta) do
    if meta[:checksum] && meta.checksum != checksum do
      aborted(to, stream, :checksum_mismatch)
    else
      case to.stream_close(stream) do
        {:ok, _url} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp aborted(to, stream, reason) do
    to.stream_abort(stream)
    {:error, reason}
  end

  # A store that takes no stream: the file downloaded, then put.
  defp through_file(key, from, to, meta) do
    path = Path.join(System.tmp_dir!(), "storehouse-copy-#{System.unique_integer([:positive])}")

    try do
      with :ok <- Storehouse.download(key, path, adapter: from),
           checksum = Storehouse.checksum(path),
           true <- meta[:checksum] in [nil, checksum] || {:error, :checksum_mismatch},
           {:ok, _url} <- to.put(key, path, Map.put(meta, :checksum, checksum)) do
        :ok
      end
    after
      File.rm(path)
    end
  end
end
