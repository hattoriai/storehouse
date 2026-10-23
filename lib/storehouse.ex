defmodule Storehouse do
  @moduledoc """
  Files for Phoenix: a file checked by its bytes (`Storehouse.Check`),
  stored under a new, safe key through a store of the app's
  (`Storehouse.Adapter`: the local disk, S3, …), and served safely
  (`Storehouse.Local.Plug`).

      {:ok, file} = Storehouse.store("priv/seeds/palette.png")
      file.url
      #=> "/uploads/2026/10/0b6…-palette.png"

  `store/2` gives a `Storehouse.File`, which the app keeps (its key, URL,
  name, type, size, and an image's width and height). A LiveView upload
  goes the same way, with `Storehouse.Live.consume/3`; a file at an
  address of a host the app allows, with `fetch/2`.

  ## The store

      config :storehouse, adapter: Storehouse.Local
      config :storehouse, Storehouse.Local, root: "/var/lib/my_app/uploads"

  `Storehouse.Local` (the default) keeps the files on the local disk; an
  app writes its own adapter for S3 or another store (see
  `Storehouse.Adapter`). Each call takes `adapter:` too.

  ## Keys

  A key is a relative path with segments of ASCII letters, digits, `.`,
  `-` and `_`, separated by `/`. A segment is never `.` or `..`. `key/2`
  makes a new key in the form `yyyy/mm/<uuid>-<safe name><extension>`.
  The extension comes from the checked content type
  (`Storehouse.Check.extension/1`), never from the client's file name, so
  a key never ends in `.html` or `.svg`. An adapter refuses a key that
  `valid_key?/1` refuses.

  ## Telemetry

  Storehouse emits `:telemetry` spans, each a `:start`, then a `:stop`
  (or an `:exception`) event, with the `:duration` of the work:

    * `[:storehouse, :store, ...]` - `store/2`, with `:name` and
      `:adapter`;
    * `[:storehouse, :fetch, ...]` - `fetch/2`, with `:url` (without its
      query) and `:adapter` (its `store/2` has a span of its own);
    * `[:storehouse, :presign_upload, ...]` - `presign_upload/4`, with
      `:name`, `:content_type`, `:bytes` and `:adapter`;
    * `[:storehouse, :verify_upload, ...]` - `verify_upload/2`, with
      `:key` and `:adapter`;
    * `[:storehouse, :delete, ...]` - `delete/2`, with `:key` and
      `:adapter`;
    * `[:storehouse, :promote, ...]` - `promote/2`, with `:key` (the
      temporary one) and `:adapter`;
    * `[:storehouse, :head, ...]`, `[:storehouse, :read, ...]` and
      `[:storehouse, :download, ...]` - `head/2`, `read/2` and
      `download/3`, with `:key` and `:adapter`;
    * `[:storehouse, :stream, ...]` - `stream/2`, with `:key` and
      `:adapter`: the stream's opening, not its reading.

  The `:stop` event's metadata has the outcome: `result: :ok` with the
  `:file` (or the `:key`), or `result: :error` with the `:reason` (a file
  refused: `:not_accepted`, `:too_large`, `:not_allowed`; a store's
  error). For example, to count the files refused:

      :telemetry.attach("storehouse-refused", [:storehouse, :store, :stop], &MyApp.Metrics.file/4, nil)
  """

  require Logger

  alias Storehouse.Check
  alias Storehouse.Oban.Analyze, as: AnalyzeJob

  # Oban is optional: these are called only with runner: :oban.
  @compile {:no_warn_undefined, [Oban, AnalyzeJob]}

  @max_name 100
  @max_display_name 200
  @max_key 255
  @max_redirects 3
  @segment ~r/\A[A-Za-z0-9._\-]+\z/

  @doc """
  Returns the configured adapter (`config :storehouse, adapter:`), by
  default `Storehouse.Local`.
  """
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:storehouse, :adapter, Storehouse.Local)

  @doc """
  Checks the file at `path` and stores it under a new key, through the
  adapter. The file at `path` is left where it is.

  The file's type is the one its bytes prove (`Storehouse.Check`): a file
  that is not of a passive type is stored as `application/octet-stream`,
  with a key that ends in `.bin`, unless `:accept` refuses it. When the
  adapter stores the file but gives a URL that is not safe to show
  (`safe_url?/1`), the stored file is deleted.

  ## Options

    * `:name` - the file's name, for its key and for display. The default
      is the base name of `path`.
    * `:content_type` - the claimed type, as a browser sends it. The
      default is the type of the name's extension. Only the bytes make an
      image an image.
    * `:accept` - the checked types to take, a list; another gives
      `{:error, :not_accepted}`. The default takes every one.
    * `:max_bytes`, `:max_pixels` - as `Storehouse.Check.describe/3`'s.
    * `:adapter` - the store. The default is `adapter/0`.
    * `:key` - a function of the name and the checked content type that
      gives the key. The default is `&key/2`.
    * `:owner` - whose file it is, for an app whose files belong to
      someone (an account, a workspace): its key is put under the owner's
      prefix, `"<owner>/…"` (`owner_key/2`). A string of key segments
      (`"accounts/42"`) or an integer.
    * `:room` - how many bytes the owner may still store: a larger file
      gives `{:error, :storage_full}`, and is not stored. The default is
      no limit.
    * `:analyze` - analysis steps (`Storehouse.Analyzer`) to run once the
      file is stored, from `path`, with no download: the file comes with
      their results. A step that fails keeps why, and the file is stored
      either way. For work out of the request, `analyze_later/3`.
    * `:metadata` - the file's own (`Storehouse.Metadata`): a caption, a
      credit. Metadata that JSON cannot hold gives
      `{:error, {:invalid_metadata, path}}`, and nothing is stored.
    * `:cache` - `true` stores the file under the temporary prefix
      (`cache_prefix/0`), until `promote/2` makes it permanent: an upload
      of a form that may never be saved.
    * `:preview` - a function of the stored file and `path` that gives
      the URL of a smaller image of it (a thumbnail, a PDF's first page, a
      video's poster), or `nil`. It runs while `path` is still there; the
      app renders and stores the image. A result that is not a safe URL,
      or an exception, gives none and logs a warning.
  """
  @spec store(Path.t(), keyword()) :: {:ok, Storehouse.File.t()} | {:error, term()}
  def store(path, opts \\ []) when is_binary(path) do
    name = clean_name(Keyword.get_lazy(opts, :name, fn -> Path.basename(path) end))
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    span(:store, %{name: name, adapter: adapter}, fn -> do_store(path, name, adapter, opts) end)
  end

  defp do_store(path, name, adapter, opts) do
    claim =
      Keyword.get_lazy(opts, :content_type, fn -> Check.content_type(Path.extname(name)) end)

    with {:ok, metadata} <- initial_metadata(opts),
         {:ok, description} <- Check.describe(path, claim, opts),
         :ok <- fits(description.bytes, opts[:room]),
         :ok <- accepted(description.content_type, Keyword.get(opts, :accept)),
         {:ok, key} <- new_key(opts, name, description.content_type),
         checksum = checksum(path),
         meta = %{
           name: name,
           content_type: description.content_type,
           bytes: description.bytes,
           checksum: checksum
         },
         {:ok, url} <- put(adapter, key, path, meta) do
      file = %Storehouse.File{
        key: key,
        url: url,
        name: name,
        content_type: description.content_type,
        bytes: description.bytes,
        width: description.width,
        height: description.height,
        checksum: checksum,
        metadata: metadata
      }

      file
      |> preview(path, Keyword.get(opts, :preview))
      |> analyze_stored(path, adapter, Keyword.get(opts, :analyze, []))
    end
  end

  defp analyze_stored(file, _path, _adapter, []), do: {:ok, file}

  defp analyze_stored(file, path, adapter, steps),
    do: Storehouse.Analyzer.run(file, steps, path: path, adapter: adapter)

  # The metadata a new file starts with.
  defp initial_metadata(opts),
    do: Storehouse.Metadata.normalize(Keyword.get(opts, :metadata, %{}))

  defp accepted(_type, nil), do: :ok

  defp accepted(type, accept) when is_list(accept),
    do: if(type in accept, do: :ok, else: {:error, :not_accepted})

  @doc false
  def new_key_for(opts, name, content_type), do: new_key(opts, name, content_type)

  # The key of a new file: the `:key` function's, or `key/2`'s; under the
  # temporary prefix with `cache: true`.
  defp new_key(opts, name, content_type) do
    with key when is_binary(key) <- Keyword.get(opts, :key, &key/2).(name, content_type),
         {:ok, key} <- under_owner(key, opts[:owner]) do
      {:ok, if(opts[:cache], do: cache_prefix() <> key, else: key)}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_key, other}}
    end
  end

  defp under_owner(key, nil), do: {:ok, key}

  defp under_owner(key, owner) do
    with {:ok, prefix} <- owner_prefix(owner), do: {:ok, prefix <> "/" <> key}
  end

  defp owner_prefix(owner) when is_integer(owner) and owner >= 0,
    do: {:ok, Integer.to_string(owner)}

  defp owner_prefix(owner) when is_binary(owner) do
    prefix = String.trim(owner, "/")
    if valid_key?(prefix), do: {:ok, prefix}, else: {:error, :invalid_owner}
  end

  defp owner_prefix(_owner), do: {:error, :invalid_owner}

  @doc """
  The key `key` would have under `owner`'s prefix: `"<owner>/<key>"`, as
  `store/2` and `presign_upload/4` make it with `:owner`.

  ## Examples

      iex> Storehouse.owner_key("accounts/42", "2026/10/a.png")
      {:ok, "accounts/42/2026/10/a.png"}

      iex> Storehouse.owner_key("../42", "a.png")
      {:error, :invalid_owner}

  """
  @spec owner_key(String.t() | non_neg_integer(), Storehouse.Adapter.key()) ::
          {:ok, Storehouse.Adapter.key()} | {:error, :invalid_owner}
  def owner_key(owner, key), do: under_owner(key, owner)

  @doc """
  Whether `key` is one of `owner`'s files: under its prefix, as `:owner`
  puts it, temporary (`cache: true`) or permanent. Check a key a browser
  sends back before you take it, so that no one claims another's file.
  `verify_upload/2` and `Storehouse.Ecto.put_file/4` check it with
  `:owner`.

  ## Examples

      iex> Storehouse.owns?("accounts/42", "accounts/42/2026/10/a.png")
      true

      iex> Storehouse.owns?("accounts/42", "accounts/421/2026/10/a.png")
      false

      iex> Storehouse.owns?(42, "cache/42/2026/10/a.png")
      true

      iex> Storehouse.owns?("accounts/42", "accounts/42/../7/a.png")
      false

  """
  @spec owns?(String.t() | non_neg_integer(), Storehouse.Adapter.key()) :: boolean()
  def owns?(owner, key) when is_binary(key) do
    with {:ok, prefix} <- owner_prefix(owner),
         true <- valid_key?(key) do
      key |> String.replace_prefix(cache_prefix(), "") |> String.starts_with?(prefix <> "/")
    else
      _not -> false
    end
  end

  def owns?(_owner, _key), do: false

  @doc """
  What `owner`'s files take in the store, counted from the store itself
  (`list/2`): `{:ok, %{bytes: bytes, files: count}}`. A store of many files
  lists them all: an app that keeps its files in records sums them there,
  and this checks it.
  """
  @spec usage(String.t() | non_neg_integer(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), files: non_neg_integer()}} | {:error, term()}
  def usage(owner, opts \\ []) do
    with {:ok, prefix} <- owner_prefix(owner),
         {:ok, entries} <- list(prefix <> "/", opts) do
      {:ok,
       Enum.reduce(entries, %{bytes: 0, files: 0}, fn entry, acc ->
         %{bytes: acc.bytes + entry.bytes, files: acc.files + 1}
       end)}
    end
  rescue
    error in Storehouse.ReadError -> {:error, error.reason}
  end

  # A file of `bytes` in the room left: `:storage_full` when it does not fit.
  defp fits(_bytes, nil), do: :ok
  defp fits(_bytes, :infinity), do: :ok
  defp fits(bytes, room) when is_integer(room) and bytes <= room, do: :ok
  defp fits(_bytes, _room), do: {:error, :storage_full}

  @doc """
  The prefix of the keys of temporary files (`cache: true`): `"cache/"`,
  or `config :storehouse, cache_prefix: "tmp/"`. A bucket's lifecycle rule
  deletes what stays there (see the Ecto guide).
  """
  @spec cache_prefix() :: String.t()
  def cache_prefix, do: Application.get_env(:storehouse, :cache_prefix, "cache/")

  @doc "Whether a file (or a key) is a temporary one, under `cache_prefix/0`."
  @spec cached?(Storehouse.File.t() | Storehouse.Adapter.key()) :: boolean()
  def cached?(%Storehouse.File{key: key}), do: cached?(key)
  def cached?(key) when is_binary(key), do: String.starts_with?(key, cache_prefix())

  @doc """
  Makes a temporary file (`cache: true`) permanent: copies it, in the
  store, to its key without the temporary prefix, deletes the temporary
  one, and gives the file at its new key. A file that is not temporary is
  given as it is.

  It can run again for the same file: when the temporary file is gone and
  the permanent one is there (a save that rolled back after it, and was
  tried again), it gives the permanent one.

  ## Options

    * `:adapter` - as for `store/2`. The adapter copies files in the store
      (`c:Storehouse.Adapter.copy/2`): `Storehouse.Local` and
      `Storehouse.S3` do; another gives `{:error, :not_supported}`.
    * `:keep_cached` - `true` keeps the temporary file. The default is
      `false`.
  """
  @spec promote(Storehouse.File.t(), keyword()) :: {:ok, Storehouse.File.t()} | {:error, term()}
  def promote(%Storehouse.File{key: key} = file, opts \\ []) do
    if cached?(key) do
      adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
      span(:promote, %{key: key, adapter: adapter}, fn -> do_promote(file, adapter, opts) end)
    else
      {:ok, file}
    end
  end

  defp do_promote(%Storehouse.File{key: from} = file, adapter, opts) do
    to = String.replace_prefix(from, cache_prefix(), "")

    with :ok <- supported(adapter, :copy, 2),
         :ok <- copy_once(adapter, from, to) do
      unless opts[:keep_cached], do: adapter.delete(from)
      {:ok, %{file | key: to, url: adapter.url(to)}}
    end
  end

  defp copy_once(adapter, from, to) do
    case adapter.copy(from, to) do
      :ok ->
        :ok

      {:error, :enoent} = error ->
        # Promoted already: the permanent file is there.
        if match?({:ok, _head, _size}, adapter.read_head(to, 1)), do: :ok, else: error

      {:error, _reason} = error ->
        error
    end
  end

  defp put(adapter, key, path, meta) do
    case adapter.put(key, path, meta) do
      {:ok, url} when is_binary(url) ->
        if safe_url?(url),
          do: {:ok, url},
          else: discard(adapter, key, {:error, {:unsafe_url, url}})

      {:error, reason} ->
        {:error, reason}

      other ->
        discard(adapter, key, {:error, {:invalid_store_result, other}})
    end
  end

  # A file the adapter stored that gives no file to keep: deleted, so that
  # nothing is left that nothing points to.
  defp discard(adapter, key, error) do
    _result = adapter.delete(key)
    error
  end

  defp preview(file, _path, nil), do: file

  defp preview(file, path, fun) do
    case fun.(file, path) do
      nil ->
        file

      url when is_binary(url) ->
        if safe_url?(url), do: %{file | preview: url}, else: no_preview(file, {:unsafe_url, url})

      other ->
        no_preview(file, {:invalid_preview, other})
    end
  rescue
    exception -> no_preview(file, exception)
  end

  defp no_preview(file, reason) do
    Logger.warning(
      "Storehouse: no preview for the file #{inspect(file.name)}: #{inspect(reason)}"
    )

    file
  end

  @doc """
  Signs an upload that a browser makes straight to the store, without the
  file going through the app: of the file `name`, of the claimed type
  `claim` and of `bytes` bytes exactly. Gives the file's new `key` and the
  request to make (`method`, `url`, `headers`). `Storehouse.Live.allow/3`
  does this for a LiveView upload.

  The key's extension is the claimed type's, as the checked type it would
  be (`Storehouse.Check.claimed/1`). When the file is there, check it
  with `verify_upload/2`: until then, it is what the browser said it is.

  ## Options

    * `:accept` - the types to take: a claim of another gives
      `{:error, :not_accepted}` at once.
    * `:max_bytes` - a larger file gives `{:error, :too_large}` at once.
    * `:expires_in` - how long the browser has to start the upload, in
      seconds. The default is 600.
    * `:owner` and `:room`, as for `store/2`: the key under the owner's
      prefix, and a file larger than the room left refused at once, with
      `{:error, :storage_full}`.
    * `:adapter` and `:key`, as for `store/2`. The adapter must sign
      uploads (`c:Storehouse.Adapter.presign_upload/3`): `Storehouse.Local`
      and `Storehouse.S3` do; another gives `{:error, :not_supported}`.
  """
  @spec presign_upload(String.t(), String.t() | nil, non_neg_integer(), keyword()) ::
          {:ok,
           %{key: Storehouse.Adapter.key(), method: String.t(), url: String.t(), headers: map()}}
          | {:error, term()}
  def presign_upload(name, claim, bytes, opts \\ []) when is_integer(bytes) and bytes >= 0 do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    type = Check.claimed(claim)
    name = clean_name(name)
    meta = %{name: name, content_type: type, bytes: bytes, adapter: adapter}
    span(:presign_upload, meta, fn -> do_presign_upload(name, type, bytes, adapter, opts) end)
  end

  defp do_presign_upload(name, type, bytes, adapter, opts) do
    with :ok <- supported(adapter, :presign_upload, 3),
         :ok <- accepted(type, Keyword.get(opts, :accept)),
         :ok <- fits(bytes, opts[:room]),
         :ok <-
           if(is_integer(opts[:max_bytes]) and bytes > opts[:max_bytes],
             do: {:error, :too_large},
             else: :ok
           ),
         {:ok, key} <- new_key(opts, name, type),
         {:ok, upload} <-
           adapter.presign_upload(key, %{name: name, content_type: type, bytes: bytes},
             expires_in: Keyword.get(opts, :expires_in, 600)
           ) do
      {:ok, Map.put(upload, :key, key)}
    end
  end

  @doc """
  Checks a file a browser uploaded straight to the store
  (`presign_upload/4`), by its first bytes, and gives it as `store/2`
  does. A file whose bytes are not of the type it was signed for (a page
  sent as a PNG), of a type `:accept` refuses, or over a limit, is
  deleted, and gives `{:error, :not_accepted}` or `{:error, :too_large}`.

  ## Options

    * `:name` - the file's name, for display. The default is the key's.
    * `:metadata` - as for `store/2`.
    * `:owner` - the owner the file must belong to (`owns?/2`): a key
      under another's prefix gives `{:error, :not_owner}`, and the file
      there is left as it is.
    * `:room` - the bytes the owner may still store, against the size the
      store gives (not the one the browser declared): a larger file gives
      `{:error, :storage_full}`, and is deleted.
    * `:accept`, `:max_bytes`, `:max_pixels`, `:adapter`, as for
      `store/2`.
    * `:preview` - as for `store/2`, with `nil` for the path: the file is
      not here.
  """
  @spec verify_upload(Storehouse.Adapter.key(), keyword()) ::
          {:ok, Storehouse.File.t()} | {:error, term()}
  def verify_upload(key, opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    span(:verify_upload, %{key: key, adapter: adapter}, fn ->
      do_verify_upload(key, adapter, opts)
    end)
  end

  defp do_verify_upload(key, adapter, opts) do
    signed = Check.content_type(Path.extname(key))

    with true <- valid_key?(key) || {:error, :invalid_key},
         # Another's file is refused, and left as it is.
         true <- (is_nil(opts[:owner]) or owns?(opts[:owner], key)) || {:error, :not_owner},
         {:ok, metadata} <- initial_metadata(opts),
         :ok <- supported(adapter, :read_head, 2),
         {:ok, head, size} <- adapter.read_head(key, Check.head_size()),
         # The size the browser declared is a claim: the store says.
         :ok <- discarded(fits(size, opts[:room]), adapter, key),
         {:ok, description} <-
           checked(Check.describe_head(head, size, signed, opts), signed, opts, adapter, key) do
      file = %Storehouse.File{
        key: key,
        url: adapter.url(key),
        name: clean_name(Keyword.get(opts, :name, Path.basename(key))),
        content_type: signed,
        bytes: description.bytes,
        width: description.width,
        height: description.height,
        checksum: stored_checksum(adapter, key),
        metadata: metadata
      }

      {:ok, preview(file, nil, Keyword.get(opts, :preview))}
    end
  end

  defp discarded(:ok, _adapter, _key), do: :ok
  defp discarded(error, adapter, key), do: discard(adapter, key, error)

  defp stored_checksum(adapter, key) do
    with :ok <- supported(adapter, :checksum, 1),
         {:ok, checksum} <- adapter.checksum(key) do
      checksum
    else
      _none -> nil
    end
  end

  @doc """
  The SHA-256 of the file at `path`, in Base64: a `Storehouse.File`'s
  `checksum`, to compare with a copy's.
  """
  @spec checksum(Path.t()) :: String.t()
  def checksum(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode64()
  end

  # The bytes are of the type the upload was signed for (any, for a
  # download), and of one taken: else the file goes.
  defp checked({:ok, %{content_type: type} = description}, signed, opts, adapter, key) do
    cond do
      signed != "application/octet-stream" and type != signed ->
        discard(adapter, key, {:error, :not_accepted})

      accepted(signed, Keyword.get(opts, :accept)) != :ok ->
        discard(adapter, key, {:error, :not_accepted})

      true ->
        {:ok, description}
    end
  end

  defp checked({:error, _reason} = error, _signed, _opts, adapter, key),
    do: discard(adapter, key, error)

  @doc """
  A URL of a file that is valid for a while, for a file that is not
  public: a bucket that is private, a local store whose plug serves only
  signed URLs (`private: true`). Keep the key, not this URL: it expires.
  `Storehouse.Redirect` gives a lasting URL of your app that redirects to
  a fresh one.

  ## Options

    * `:expires_in` - in seconds. The default is 300.
    * `:disposition` - `"inline"` or `"attachment"` (a download).
    * `:filename` - the name of the download.
    * `:adapter` - as for `store/2`. The adapter must sign URLs
      (`c:Storehouse.Adapter.signed_url/2`): `Storehouse.Local` and
      `Storehouse.S3` do; another gives `{:error, :not_supported}`.
  """
  @spec signed_url(Storehouse.Adapter.key() | Storehouse.File.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def signed_url(key_or_file, opts \\ [])
  def signed_url(%Storehouse.File{key: key}, opts), do: signed_url(key, opts)

  def signed_url(key, opts) when is_binary(key) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    with :ok <- supported(adapter, :signed_url, 2),
         true <- valid_key?(key) || {:error, :invalid_key} do
      adapter.signed_url(
        key,
        Keyword.merge(
          [expires_in: 300],
          Keyword.take(opts, [:expires_in, :disposition, :filename])
        )
      )
    end
  end

  @doc """
  What the store knows of the file with `key`, without reading it: its
  `:bytes`, its `:content_type` as stored (or `nil`), and its `:checksum`
  (or `nil`). A missing file gives `{:error, :enoent}`.

  The size a browser declares for an upload is a claim: ask the store
  before reading a file it sent.

  ## Options

    * `:adapter` - as for `store/2`. The adapter must read files
      (`c:Storehouse.Adapter.head/1` and `c:Storehouse.Adapter.read_range/3`):
      `Storehouse.Local` and `Storehouse.S3` do; another gives
      `{:error, :not_supported}`.
  """
  @spec head(Storehouse.Adapter.key() | Storehouse.File.t(), keyword()) ::
          {:ok, Storehouse.Adapter.head()} | {:error, term()}
  def head(key_or_file, opts \\ [])
  def head(%Storehouse.File{key: key}, opts), do: head(key, opts)

  def head(key, opts) when is_binary(key) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    span(:head, %{key: key, adapter: adapter}, fn -> do_head(adapter, key) end)
  end

  defp do_head(adapter, key) do
    with :ok <- readable(adapter),
         true <- valid_key?(key) || {:error, :invalid_key} do
      adapter.head(key)
    end
  end

  defp readable(adapter) do
    with :ok <- supported(adapter, :head, 1), do: supported(adapter, :read_range, 3)
  end

  @doc """
  The bytes of the file with `key`, all at once: to work on a file the
  app keeps (read its metadata, make a smaller image of it, send it on).
  For a large file, `stream/2` or `download/3`.

  Its size is asked first (`head/2`): a file larger than `:max_bytes`
  gives `{:error, {:too_large, bytes}}` before a byte of it is read, and
  no more than that size is ever read.

  ## Options

    * `:max_bytes` - the largest file to read. The default is no limit.
    * `:adapter` - as for `head/2`.
  """
  @spec read(Storehouse.Adapter.key() | Storehouse.File.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def read(key_or_file, opts \\ [])
  def read(%Storehouse.File{key: key}, opts), do: read(key, opts)

  def read(key, opts) when is_binary(key) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    span(:read, %{key: key, adapter: adapter}, fn -> do_read(adapter, key, opts) end)
  end

  defp do_read(adapter, key, opts) do
    case sized(adapter, key, opts[:max_bytes]) do
      {:ok, %{bytes: 0}} -> {:ok, ""}
      {:ok, %{bytes: bytes}} -> adapter.read_range(key, 0, bytes - 1)
      error -> error
    end
  end

  # The file's head, when it is no larger than `max`.
  defp sized(adapter, key, max) do
    case do_head(adapter, key) do
      {:ok, %{bytes: bytes}} when is_integer(max) and bytes > max -> {:error, {:too_large, bytes}}
      other -> other
    end
  end

  @doc """
  The file with `key` as a stream of its bytes, `:chunk_bytes` at a
  time, each read from the store as the stream is taken: a large file
  sent on, into a zip, through the app, with no more of it in memory than
  a chunk.

  Its size is asked at once (`head/2`), so a missing file gives
  `{:error, :enoent}` here and a file larger than `:max_bytes`
  `{:error, {:too_large, bytes}}`. A store's error while the stream is
  taken raises `Storehouse.ReadError`.

  ## Options

    * `:chunk_bytes` - the size of each read. The default is 4 MiB.
    * `:max_bytes` - the largest file to stream. The default is no limit.
    * `:adapter` - as for `head/2`.
  """
  @spec stream(Storehouse.Adapter.key() | Storehouse.File.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(key_or_file, opts \\ [])
  def stream(%Storehouse.File{key: key}, opts), do: stream(key, opts)

  def stream(key, opts) when is_binary(key) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    chunk = Keyword.get(opts, :chunk_bytes, 4 * 1_048_576)

    unless is_integer(chunk) and chunk > 0,
      do: raise(ArgumentError, ":chunk_bytes must be a positive integer, got: #{inspect(chunk)}")

    span(:stream, %{key: key, adapter: adapter}, fn ->
      with {:ok, %{bytes: bytes}} <- sized(adapter, key, opts[:max_bytes]) do
        {:ok, Stream.unfold(0, &next_chunk(adapter, key, &1, bytes, chunk))}
      end
    end)
  end

  defp next_chunk(_adapter, _key, offset, bytes, _chunk) when offset >= bytes, do: nil

  defp next_chunk(adapter, key, offset, bytes, chunk) do
    case adapter.read_range(key, offset, min(offset + chunk, bytes) - 1) do
      # The file is shorter than it was: it ends here.
      {:ok, ""} -> nil
      {:ok, data} -> {data, offset + byte_size(data)}
      {:error, reason} -> raise Storehouse.ReadError, key: key, reason: reason
    end
  end

  @doc """
  Writes the file with `key` to `path`, a chunk at a time (`stream/2`):
  for a tool that wants a file on the disk (libvips, ffmpeg, a zip).
  `path` is replaced; on an error, nothing is left there.

  ## Options

    * `:chunk_bytes`, `:max_bytes` and `:adapter` - as for `stream/2`.
  """
  @spec download(Storehouse.Adapter.key() | Storehouse.File.t(), Path.t(), keyword()) ::
          :ok | {:error, term()}
  def download(key_or_file, path, opts \\ [])
  def download(%Storehouse.File{key: key}, path, opts), do: download(key, path, opts)

  def download(key, path, opts) when is_binary(key) and is_binary(path) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    span(:download, %{key: key, adapter: adapter}, fn ->
      with {:ok, stream} <- stream(key, Keyword.put(opts, :adapter, adapter)) do
        write_download(stream, path)
      end
    end)
  end

  defp write_download(stream, path) do
    _file = Enum.into(stream, File.stream!(path))
    :ok
  rescue
    error in [Storehouse.ReadError, File.Error] ->
      File.rm(path)
      {:error, error.reason}
  end

  @doc """
  Runs the analysis steps of a file at once (`Storehouse.Analyzer`), each
  one's analysis kept in the file's `:analysis`: `{:ok, file}`.
  A step that fails keeps why, and leaves the others' results;
  `{:error, reason}` is for a file that could not be read for them.

  ## Options

    * `:force` - runs the steps whose result the file has already. The
      default is `false`.
    * `:max_bytes` - the largest file to read for them (`download/3`).
    * `:adapter` - as for `store/2`.
  """
  @spec analyze(Storehouse.File.t(), [Storehouse.Analyzer.step()], keyword()) ::
          {:ok, Storehouse.File.t()} | {:error, term()}
  def analyze(%Storehouse.File{} = file, steps, opts \\ []) when is_list(steps) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    Storehouse.Analyzer.run(file, steps, Keyword.put(opts, :adapter, adapter))
  end

  @doc """
  Runs the analysis steps of a file out of the request, then gives the
  file with their results to the app's `:then`, to save them:
  `Storehouse.Ecto.analyze_later/5` saves them in a record's column.

      Storehouse.analyze_later(file, [MyApp.Analyzers.Pages],
        then: {MyApp.Documents, :analyzed, [document.id]}
      )

  `:then` is `{module, function, args}`, called with the file first, then
  `args`. A file that cannot be read for the steps gives it nothing: with
  Oban, the job is tried again.

  ## Options

    * `:then` - the function (required).
    * `:runner` - `:task` (the default) runs them in `Storehouse.Tasks`, a
      supervisor of the app's, or at once without it; `:oban` in an Oban
      job (`Storehouse.Oban.Analyze`), which outlives a deploy.
    * `:oban` - for `runner: :oban`, the job's options (`:queue`,
      `:max_attempts`, …) and `:name`, the Oban instance (the default is
      `Oban`).
    * `:force`, `:max_bytes` and `:adapter` - as for `analyze/3`.
  """
  @spec analyze_later(Storehouse.File.t(), [Storehouse.Analyzer.step()], keyword()) ::
          :ok | {:error, term()}
  def analyze_later(%Storehouse.File{} = file, steps, opts) when is_list(steps) do
    {module, function, args} = Keyword.fetch!(opts, :then)
    true = is_atom(module) and is_atom(function) and is_list(args)
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    later = opts |> Keyword.take([:then, :force, :max_bytes]) |> Keyword.put(:adapter, adapter)

    case Keyword.get(opts, :runner, :task) do
      :task -> Storehouse.Tasks.run(fn -> analyze_now(file, steps, later) end)
      :oban -> analyze_in_oban(file, steps, later, Keyword.get(opts, :oban, []))
    end
  end

  defp analyze_in_oban(file, steps, later, oban) do
    {name, job} = Keyword.pop(oban, :name, Oban)
    term = Base.encode64(:erlang.term_to_binary({file, steps, later}))
    names = Enum.map(steps, &Storehouse.Analyzer.name/1)

    case Oban.insert(
           name,
           AnalyzeJob.new(%{key: file.key, steps: names, term: term}, job)
         ) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # The work of analyze_later/3: the steps, then the app's function.
  def analyze_now(file, steps, opts) do
    {module, function, args} = Keyword.fetch!(opts, :then)

    with {:ok, file} <- analyze(file, steps, opts) do
      _result = apply(module, function, [file | args])
      :ok
    end
  end

  defp supported(adapter, function, arity) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity),
      do: :ok,
      else: {:error, :not_supported}
  end

  @doc false
  def supports?(adapter, function, arity), do: supported(adapter, function, arity) == :ok

  @doc """
  Downloads the file at `url`, from a host of `:hosts`, then checks and
  stores it as `store/2` does: an image pasted by its address, a file an
  agent names.

  Only `https` addresses (and `http`, with `http: true`) of the hosts the
  app allows are fetched, and a redirect only to one of them: the server
  never fetches an address a person or an agent chose freely, which could
  be one of the app's own network. A host is a name (`"images.example.com"`)
  or a name with a leading `*.` for its subdomains (`"*.example.com"`).

  ## Options

    * `:hosts` - the hosts it fetches from (required).
    * `:http` - whether `http` addresses are fetched. The default is
      `false`.
    * `:timeout` - in milliseconds, to connect and for the answer. The
      default is 10 seconds.
    * the options of `store/2`; `:max_bytes` stops a download as soon as
      it is larger.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Storehouse.File.t()} | {:error, term()}
  def fetch(url, opts) when is_binary(url) do
    # The address, without its query: it may carry a token.
    address = url |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
    meta = %{url: address, adapter: Keyword.get_lazy(opts, :adapter, &adapter/0)}
    span(:fetch, meta, fn -> do_fetch(url, opts) end)
  end

  defp do_fetch(url, opts) do
    hosts = Keyword.fetch!(opts, :hosts)
    schemes = if Keyword.get(opts, :http, false), do: ["https", "http"], else: ["https"]

    with {:ok, uri} <- allowed(url, hosts, schemes),
         {:ok, path, uri} <- download(uri, hosts, schemes, opts, @max_redirects) do
      try do
        name = uri.path |> to_string() |> Path.basename() |> URI.decode()
        store(path, Keyword.put_new(opts, :name, if(name == "", do: "file", else: name)))
      after
        File.rm(path)
      end
    end
  end

  @doc """
  Whether `fetch/2` takes `url` with `hosts` (`https` only).

  ## Examples

      iex> Storehouse.fetchable?("https://images.example.com/a.png", ["*.example.com"])
      true

      iex> Storehouse.fetchable?("https://example.com.evil.org/a.png", ["*.example.com"])
      false

  """
  @spec fetchable?(String.t(), [String.t()]) :: boolean()
  def fetchable?(url, hosts), do: match?({:ok, _uri}, allowed(url, hosts, ["https"]))

  defp allowed(url, hosts, schemes) do
    with %URI{scheme: scheme, host: host} = uri when is_binary(host) <- URI.parse(url),
         true <- scheme in schemes,
         true <- host_allowed?(String.downcase(host), hosts) do
      {:ok, uri}
    else
      _other -> {:error, :not_allowed}
    end
  end

  defp host_allowed?(host, hosts) do
    Enum.any?(hosts, fn
      "*." <> domain -> String.ends_with?(host, "." <> String.downcase(domain))
      allowed -> host == String.downcase(allowed)
    end)
  end

  defp download(_uri, _hosts, _schemes, _opts, -1), do: {:error, :too_many_redirects}

  defp download(uri, hosts, schemes, opts, redirects) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])
    timeout = Keyword.get(opts, :timeout, 10_000)
    path = Path.join(System.tmp_dir!(), "storehouse-#{System.unique_integer([:positive])}")

    http_opts = [
      timeout: timeout,
      connect_timeout: timeout,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    request = {String.to_charlist(URI.to_string(uri)), []}

    case :httpc.request(:get, request, http_opts, sync: false, stream: :self) do
      {:ok, ref} ->
        case receive_body(ref, path, opts[:max_bytes], timeout) do
          :ok -> {:ok, path, uri}
          {:redirect, location} -> redirect(uri, location, hosts, schemes, opts, redirects, path)
          {:error, _reason} = error -> discard_download(path, error)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect(uri, location, hosts, schemes, opts, redirects, path) do
    File.rm(path)

    with {:ok, next} <- allowed(URI.to_string(URI.merge(uri, location)), hosts, schemes) do
      download(next, hosts, schemes, opts, redirects - 1)
    end
  end

  defp discard_download(path, error) do
    File.rm(path)
    error
  end

  # The answer, streamed to a file, and no more of it than `max` bytes.
  defp receive_body(ref, path, max, timeout) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        File.write!(path, "")
        receive_chunks(ref, path, max, timeout, 0)

      {:http, {^ref, {{_version, status, _reason}, headers, _body}}}
      when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, ~c"location", 0) do
          {_name, location} -> {:redirect, to_string(location)}
          nil -> {:error, {:http, status}}
        end

      {:http, {^ref, {{_version, status, _reason}, _headers, body}}} when status in 200..299 ->
        # A short answer, all at once.
        if is_integer(max) and byte_size(body) > max,
          do: {:error, :too_large},
          else: File.write(path, body)

      {:http, {^ref, {{_version, status, _reason}, _headers, _body}}} ->
        {:error, {:http, status}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  defp receive_chunks(ref, path, max, timeout, size) do
    receive do
      {:http, {^ref, :stream, chunk}} ->
        size = size + byte_size(chunk)

        if is_integer(max) and size > max do
          :httpc.cancel_request(ref)
          {:error, :too_large}
        else
          File.write!(path, chunk, [:append])
          receive_chunks(ref, path, max, timeout, size)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  @doc "Deletes the file with `key`, through the adapter (`:adapter`, or `adapter/0`)."
  @spec delete(Storehouse.Adapter.key(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)
    span(:delete, %{key: key, adapter: adapter}, fn -> adapter.delete(key) end)
  end

  @doc """
  The files whose keys start with `prefix`, as a stream of maps with their
  `:key`, `:bytes` and `:modified_at` (a `DateTime`), in the order of their
  keys: an account's files, the temporary ones, those of a file's
  versions. The store is asked a page at a time, as the stream is taken,
  and a store's error then raises `Storehouse.ReadError`. A key the store
  has that `valid_key?/1` refuses is left out.

  A prefix is a key, or the start of one: `"cache/"`, `"accounts/42/"`,
  `"2026/10/0b6"`. Another gives `{:error, :invalid_prefix}`.

  ## Options

    * `:adapter` - as for `store/2`. The adapter must list files
      (`c:Storehouse.Adapter.list/1`): `Storehouse.Local` and
      `Storehouse.S3` do; another gives `{:error, :not_supported}`.
  """
  @spec list(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def list(prefix, opts \\ []) when is_binary(prefix) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    with true <- valid_prefix?(prefix) || {:error, :invalid_prefix},
         :ok <- supported(adapter, :list, 1),
         {:ok, entries} <- adapter.list(prefix) do
      {:ok, Stream.filter(entries, &valid_key?(&1.key))}
    end
  end

  @doc """
  Deletes every file whose key starts with `prefix` (see `list/2`): an
  account's files when it goes, every version of a file. A thousand keys
  at a time where the store deletes many at once
  (`c:Storehouse.Adapter.delete_many/1`), one at a time where it does not.
  Gives `{:ok, count}`, the number of files deleted.

  The prefix is never empty: `""` and `"/"` give `{:error, :invalid_prefix}`,
  as every prefix `list/2` refuses does.

  ## Options

    * `:adapter` - as for `list/2`.
  """
  @spec delete_prefix(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_prefix(prefix, opts \\ []) when is_binary(prefix) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    span(:delete_prefix, %{prefix: prefix, adapter: adapter}, fn ->
      with {:ok, entries} <- list(prefix, adapter: adapter) do
        entries |> Stream.map(& &1.key) |> delete_keys(adapter)
      end
    end)
  end

  @doc false
  # Deletes the keys of a stream, a thousand at a time: `{:ok, count}`.
  def delete_keys(keys, adapter) do
    keys
    |> Stream.chunk_every(1_000)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, count} ->
      case delete_batch(adapter, batch) do
        :ok -> {:cont, {:ok, count + length(batch)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  rescue
    error in Storehouse.ReadError -> {:error, error.reason}
  end

  defp delete_batch(adapter, keys) do
    if supports?(adapter, :delete_many, 1),
      do: adapter.delete_many(keys),
      else: Enum.reduce_while(keys, :ok, &delete_one(adapter, &1, &2))
  end

  defp delete_one(adapter, key, :ok) do
    case adapter.delete(key) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc """
  Deletes the file with `key` later, and again until the store answers:
  a file replaced or removed, whose record is already saved. With
  `Storehouse.Cleaner` in the app's supervision tree, the deletion is
  queued there and retried when the store fails; without it, the file is
  deleted at once, as `delete/2` does.

  Gives `:ok`, or `{:error, :invalid_key}` for a key `valid_key?/1`
  refuses. Takes `:adapter`, as `delete/2` does.
  """
  @spec delete_later(Storehouse.Adapter.key(), keyword()) :: :ok | {:error, term()}
  def delete_later(key, opts \\ []) when is_binary(key) do
    if valid_key?(key),
      do: Storehouse.Cleaner.queue({:key, key}, opts),
      else: {:error, :invalid_key}
  end

  @doc """
  As `delete_later/2`, for every file whose key starts with `prefix`
  (`delete_prefix/2`): an account's files when it goes. Gives `:ok`, or
  `{:error, :invalid_prefix}`.
  """
  @spec delete_prefix_later(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_prefix_later(prefix, opts \\ []) when is_binary(prefix) do
    if valid_prefix?(prefix),
      do: Storehouse.Cleaner.queue({:prefix, prefix}, opts),
      else: {:error, :invalid_prefix}
  end

  @doc """
  Whether `prefix` is a key or the start of one, for `list/2` and
  `delete_prefix/2`: never empty, never `"/"`.

  ## Examples

      iex> Storehouse.valid_prefix?("accounts/42/")
      true

      iex> Storehouse.valid_prefix?("2026/10/0b6")
      true

      iex> Storehouse.valid_prefix?("/")
      false

      iex> Storehouse.valid_prefix?("../")
      false

  """
  @spec valid_prefix?(term()) :: boolean()
  def valid_prefix?(prefix) when is_binary(prefix),
    do:
      prefix |> String.trim_trailing("/") |> valid_key?() and not String.ends_with?(prefix, "//")

  def valid_prefix?(_prefix), do: false

  # A span of telemetry events (see the module doc): its outcome in the
  # stop event's metadata.
  defp span(event, meta, fun) do
    :telemetry.span([:storehouse, event], meta, fn ->
      result = fun.()
      {result, Map.merge(meta, outcome(result))}
    end)
  end

  defp outcome({:ok, %Storehouse.File{} = file}), do: %{result: :ok, file: file}
  defp outcome({:ok, %{key: key}}), do: %{result: :ok, key: key}
  defp outcome({:ok, _other}), do: %{result: :ok}
  defp outcome(:ok), do: %{result: :ok}
  defp outcome({:error, reason}), do: %{result: :error, reason: reason}

  @doc "Returns the URL of the file with `key`, through the adapter (`:adapter`, or `adapter/0`)."
  @spec url(Storehouse.Adapter.key(), keyword()) :: String.t()
  def url(key, opts \\ []), do: Keyword.get_lazy(opts, :adapter, &adapter/0).url(key)

  @doc """
  Returns a new key for a file: `yyyy/mm/<uuid>-<safe name><extension>`,
  with the year and month of now (UTC), a random UUID, and the extension
  of the checked content type (see `safe_name/2`).

  ## Examples

      iex> key = Storehouse.key("My cat (1).png", "image/png")
      iex> [_year, _month, file] = String.split(key, "/")
      iex> String.slice(file, 37..-1//1)
      "My_cat_1_.png"

      iex> "evil.svg" |> Storehouse.key("application/octet-stream") |> Path.extname()
      ".bin"

  """
  @spec key(String.t(), String.t()) :: Storehouse.Adapter.key()
  def key(name, content_type) when is_binary(name) and is_binary(content_type) do
    now = DateTime.utc_now()
    year = now.year |> Integer.to_string() |> String.pad_leading(4, "0")
    month = now.month |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{year}/#{month}/#{uuid()}-#{safe_name(name, content_type)}"
  end

  @doc """
  Returns a safe file name for a key: the client's name without its
  extension, with only ASCII letters, digits, `.`, `-` and `_`, then the
  extension of the checked content type. At most #{@max_name} characters.

  Every run of other characters becomes one `_`, and a run of dots becomes
  one dot. A name with nothing left is `"file"`.

  ## Examples

      iex> Storehouse.safe_name("résumé 2026.pdf", "application/pdf")
      "r_sum_2026.pdf"

      iex> Storehouse.safe_name("photo.html", "image/png")
      "photo.png"

      iex> Storehouse.safe_name("../../etc/passwd", "application/octet-stream")
      "._._etc_passwd.bin"

      iex> Storehouse.safe_name("", "text/plain")
      "file.txt"

  """
  @spec safe_name(String.t(), String.t()) :: String.t()
  def safe_name(name, content_type) when is_binary(name) and is_binary(content_type) do
    ext = Check.extension(content_type)

    base =
      name
      |> Path.rootname()
      |> String.replace(~r/[^A-Za-z0-9._\-]+/, "_")
      |> String.replace(~r/\.{2,}/, ".")
      |> String.trim_trailing(".")

    base = if base in ["", "_"], do: "file", else: base
    binary_part(base, 0, min(byte_size(base), @max_name - byte_size(ext))) <> ext
  end

  @doc """
  Returns `true` when `key` is a valid storage key (see the module doc).

  ## Examples

      iex> Storehouse.valid_key?("2026/10/a-cat.png")
      true

      iex> Storehouse.valid_key?("2026/../../etc/passwd")
      false

      iex> Storehouse.valid_key?("/etc/passwd")
      false

  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) in 1..@max_key do
    key |> String.split("/") |> Enum.all?(&valid_segment?/1)
  end

  def valid_key?(_key), do: false

  @doc false
  @spec valid_segment?(String.t()) :: boolean()
  def valid_segment?(segment) when segment in ["", ".", ".."], do: false
  def valid_segment?(segment) when is_binary(segment), do: Regex.match?(@segment, segment)

  @doc """
  Returns a file name for display: control and format characters (bidi
  controls included) removed, at most #{@max_display_name} characters, and
  `"file"` when nothing is left.

  ## Examples

      iex> Storehouse.clean_name("cat\\u0000.png")
      "cat.png"

      iex> Storehouse.clean_name("a\\u202Egnp.exe")
      "agnp.exe"

  """
  @spec clean_name(term()) :: String.t()
  def clean_name(name) when is_binary(name) do
    name =
      if String.valid?(name),
        do: name,
        else: name |> String.codepoints() |> Enum.filter(&String.valid?/1) |> Enum.join()

    name
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "")
    |> String.trim()
    |> String.slice(0, @max_display_name)
    |> case do
      "" -> "file"
      clean -> clean
    end
  end

  def clean_name(_name), do: "file"

  @doc """
  Whether `url` is safe to show and link to: `http` or `https`, or a path
  of the app (`/uploads/…`, not `//host`).

  ## Examples

      iex> Storehouse.safe_url?("/uploads/a.png")
      true

      iex> Storehouse.safe_url?("javascript:alert(1)")
      false

      iex> Storehouse.safe_url?("//evil.example/a.png")
      false

  """
  @spec safe_url?(term()) :: boolean()
  def safe_url?("/" <> rest = url) when byte_size(url) <= 2_048,
    do:
      not String.starts_with?(rest, ["/", "\\"]) and
        not String.contains?(url, ["\"", "<", ">"]) and String.printable?(url)

  def safe_url?(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != "" and not String.contains?(url, ["\"", "<", ">"]) and String.printable?(url)

      _other ->
        false
    end
  end

  def safe_url?(_url), do: false

  defp uuid do
    <<a::48, _version::4, b::12, _variant::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end
end
