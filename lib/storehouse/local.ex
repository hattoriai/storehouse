defmodule Storehouse.Local do
  @moduledoc """
  A `Storehouse.Adapter` that keeps files in a directory on the local
  disk.

      # config/config.exs
      config :storehouse, adapter: Storehouse.Local

      # config/runtime.exs, in the :prod block
      if config_env() == :prod do
        config :storehouse, Storehouse.Local,
          root: System.get_env("UPLOADS", "/var/lib/my_app/uploads"),
          url_prefix: "/uploads"
      end

      # config/dev.exs
      config :storehouse, Storehouse.Local, root: Path.expand("../tmp/uploads", __DIR__)

    * `:root` - the directory for the files (required). In production,
      give an absolute path outside the release, from the `:prod` block of
      `config/runtime.exs` (`runtime.exs` runs in every environment, so
      outside that block it replaces the development root). A relative path
      is relative to the current working directory, and in a release the
      files would go into the release directory and be lost on the next
      deploy.
    * `:url_prefix` - the path at which the files are served. The default
      is `"/uploads"`. When `Storehouse.Local.Plug` serves the
      files, this is a path, not a full URL: the plug matches requests
      under it.

    * `:secret` - a secret of at least 32 bytes, for signed URLs
      (`Storehouse.signed_url/2`) and uploads straight from the browser
      (`Storehouse.presign_upload/4`): the plug serves and takes only what
      it signed. Give one from the environment in production, as the
      endpoint's `secret_key_base` is:

          config :storehouse, Storehouse.Local, secret: System.fetch_env!("STOREHOUSE_SECRET")

  Serve the files with `Storehouse.Local.Plug`. Any other way to serve
  them must send `X-Content-Type-Options: nosniff`, a content type from the
  allow-list of `Storehouse.Check`, and `Content-Disposition: attachment`
  for every type that is not an image, a PDF or a video, as the plug does. A key is
  always a relative path under the root: a key that
  `Storehouse.valid_key?/1` refuses gives `{:error, :invalid_key}`, so
  a key cannot reach a file outside the root.
  """

  @behaviour Storehouse.Adapter

  @doc """
  Defines a store of its own, with a config of its own: a second bucket
  beside the first (public and private files, media on R2, files kept in
  another region).

      defmodule MyApp.PrivateFiles, do: use Storehouse.Local

      config :storehouse, MyApp.PrivateFiles, root: "/var/lib/my_app/scratch", url_prefix: "/scratch", secret: …

  The module is a `Storehouse.Adapter`: give it as `adapter:` (or a field's
  `store:`, `Storehouse.Ecto.File`), and serve its files with a plug of
  their own, `plug Storehouse.Local.Plug, store: MyApp.Scratch`. With `otp_app: :my_app`, its config is
  `config :my_app, MyApp.PrivateFiles, …`.
  """
  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app, :storehouse)

    quote do
      @behaviour Storehouse.Adapter

      @doc false
      def config, do: Application.get_env(unquote(otp_app), __MODULE__, [])

      @impl true
      def put(key, path, meta), do: Storehouse.Local.put(config(), key, path, meta)
      @impl true
      def url(key), do: Storehouse.Local.url(config(), key)
      @impl true
      def delete(key), do: Storehouse.Local.delete(config(), key)
      @impl true
      def presign_upload(key, meta, opts),
        do: Storehouse.Local.presign_upload(config(), key, meta, opts)

      @impl true
      def signed_url(key, opts), do: Storehouse.Local.signed_url(config(), key, opts)
      @impl true
      def read_head(key, bytes), do: Storehouse.Local.read_head(config(), key, bytes)
      @impl true
      def head(key), do: Storehouse.Local.head(config(), key)
      @impl true
      def read_range(key, first, last),
        do: Storehouse.Local.read_range(config(), key, first, last)

      @impl true
      def list(prefix), do: Storehouse.Local.list(config(), prefix)
      @impl true
      def delete_many(keys), do: Storehouse.Local.delete_many(config(), keys)
      @impl true
      def copy(from, to), do: Storehouse.Local.copy(config(), from, to)
      @impl true
      def checksum(key), do: Storehouse.Local.checksum(config(), key)
      @impl true
      def stream_open(key, meta), do: Storehouse.Local.stream_open(config(), key, meta)
      # A stream carries its store's config.
      @impl true
      def stream_write(stream, data), do: Storehouse.Local.stream_write(stream, data)
      @impl true
      def stream_close(stream), do: Storehouse.Local.stream_close(stream)
      @impl true
      def stream_abort(stream), do: Storehouse.Local.stream_abort(stream)
    end
  end

  alias Storehouse.Check

  @default_prefix "/uploads"

  # A file `stream_open/2` writes to, until `stream_close/1` renames it.
  @part ~r/\.part-\d+\z/

  @impl Storehouse.Adapter
  def put(key, path, meta), do: put(config(), key, path, meta)

  @doc false
  def put(c, key, path, _meta) do
    with {:ok, destination} <- path(c, key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(path, destination) do
      {:ok, url(c, key)}
    end
  end

  @impl Storehouse.Adapter
  def url(key), do: url(config(), key)

  @doc false
  def url(c, key) when is_binary(key), do: String.trim_trailing(url_prefix(c), "/") <> "/" <> key

  @impl Storehouse.Adapter
  def delete(key), do: delete(config(), key)

  @doc false
  def delete(c, key) do
    with {:ok, path} <- path(c, key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns the path on disk of the file with `key`, or
  `{:error, :invalid_key}`.
  """
  @spec path(Storehouse.Adapter.key()) :: {:ok, Path.t()} | {:error, :invalid_key}
  def path(key), do: path(config(), key)

  @doc false
  def path(c, key) do
    root = root(c)

    with true <- Storehouse.valid_key?(key),
         path = Path.expand(key, root),
         true <- String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      false -> {:error, :invalid_key}
    end
  end

  @doc """
  Returns the configured root directory, as an absolute path.

  Raises `ArgumentError` when no root is configured.
  """
  @spec root() :: Path.t()
  def root, do: root(config())

  @doc false
  def root(c) do
    case Keyword.get(c, :root) do
      root when is_binary(root) and root != "" ->
        Path.expand(root)

      _missing ->
        raise ArgumentError, """
        Storehouse.Local needs a root directory:

            config :storehouse, Storehouse.Local, root: "tmp/uploads"
        """
    end
  end

  @doc "Returns the configured URL prefix, by default `\"#{@default_prefix}\"`."
  @spec url_prefix() :: String.t()
  def url_prefix, do: url_prefix(config())

  @doc false
  def url_prefix(c), do: Keyword.get(c, :url_prefix, @default_prefix)

  @impl Storehouse.Adapter
  def presign_upload(key, meta, opts), do: presign_upload(config(), key, meta, opts)

  @doc false
  def presign_upload(c, key, meta, opts) do
    with {:ok, _path} <- path(c, key) do
      expires = System.system_time(:second) + Keyword.get(opts, :expires_in, 600)
      type = Map.fetch!(meta, :content_type)
      bytes = Map.fetch!(meta, :bytes)
      checksum = meta[:checksum]
      signature = sign(c, ["PUT", key, expires, type, bytes] ++ List.wrap(checksum))

      query =
        %{"expires" => expires, "type" => type, "bytes" => bytes, "signature" => signature}
        |> then(&if checksum, do: Map.put(&1, "checksum", checksum), else: &1)
        |> URI.encode_query()

      {:ok,
       %{method: "PUT", url: url(c, key) <> "?" <> query, headers: %{"content-type" => type}}}
    end
  end

  @impl Storehouse.Adapter
  def signed_url(key, opts), do: signed_url(config(), key, opts)

  @doc false
  def signed_url(c, key, opts) do
    with {:ok, _path} <- path(c, key) do
      expires = System.system_time(:second) + Keyword.get(opts, :expires_in, 300)
      disposition = disposition(opts)

      params =
        %{"expires" => expires, "signature" => sign(c, ["GET", key, expires, disposition])}
        |> then(&if disposition == "", do: &1, else: Map.put(&1, "disposition", disposition))

      {:ok, url(c, key) <> "?" <> URI.encode_query(params)}
    end
  end

  # `attachment; filename="board.png"`, or "" for the plug's own.
  defp disposition(opts) do
    case {opts[:disposition], opts[:filename]} do
      {nil, nil} ->
        ""

      {kind, nil} ->
        to_string(kind)

      {kind, name} ->
        ~s(#{kind || "attachment"}; filename="#{String.replace(name, ~r/[^A-Za-z0-9._\- ]/, "_")}")
    end
  end

  @impl Storehouse.Adapter
  def read_head(key, bytes), do: read_head(config(), key, bytes)

  @doc false
  def read_head(c, key, bytes) do
    with {:ok, path} <- path(c, key),
         {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(path),
         {:ok, read} <- File.open(path, [:read, :binary], &IO.binread(&1, bytes)) do
      case read do
        :eof -> {:ok, "", size}
        {:error, reason} -> {:error, reason}
        head -> {:ok, head, size}
      end
    else
      {:ok, %File.Stat{}} -> {:error, :enoent}
      error -> error
    end
  end

  # The local disk keeps no type: a key's extension is its checked type's
  # (`Storehouse.key/2`), as the plug serves it.
  @impl Storehouse.Adapter
  def head(key), do: head(config(), key)

  @doc false
  def head(c, key) do
    with {:ok, path} <- path(c, key),
         {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(path) do
      {:ok, %{bytes: size, content_type: Check.content_type(Path.extname(key)), checksum: nil}}
    else
      {:ok, %File.Stat{}} -> {:error, :enoent}
      error -> error
    end
  end

  @impl Storehouse.Adapter
  def read_range(key, first, last), do: read_range(config(), key, first, last)

  @doc false
  def read_range(c, key, first, last) when first >= 0 and last >= first do
    with {:ok, path} <- path(c, key),
         true <- File.regular?(path) || {:error, :enoent},
         {:ok, read} <-
           File.open(path, [:read, :binary], &:file.pread(&1, first, last - first + 1)) do
      case read do
        {:ok, data} -> {:ok, data}
        :eof -> {:ok, ""}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The files under the prefix's directory, but for those of streams not
  # closed yet (`stream_open/2`), in the order of their keys.
  @impl Storehouse.Adapter
  def list(prefix), do: list(config(), prefix)

  @doc false
  def list(c, prefix) do
    root = root(c)
    dir = if String.ends_with?(prefix, "/"), do: prefix, else: Path.dirname(prefix)

    entries =
      Path.join([root, dir, "**"])
      |> Path.wildcard(match_dot: true)
      |> Enum.flat_map(fn path ->
        key = Path.relative_to(path, root)

        with true <- String.starts_with?(key, prefix) and not Regex.match?(@part, key),
             {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
               File.stat(path, time: :posix) do
          [%{key: key, bytes: size, modified_at: DateTime.from_unix!(mtime)}]
        else
          _other -> []
        end
      end)
      |> Enum.sort_by(& &1.key)

    {:ok, entries}
  end

  @impl Storehouse.Adapter
  def delete_many(keys), do: delete_many(config(), keys)

  @doc false
  def delete_many(c, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case delete(c, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl Storehouse.Adapter
  def stream_open(key, meta), do: stream_open(config(), key, meta)

  @doc false
  def stream_open(c, key, _meta) do
    with {:ok, path} <- path(c, key),
         false <- File.exists?(path) && {:error, :eexist},
         :ok <- File.mkdir_p(Path.dirname(path)),
         part = path <> ".part-" <> Integer.to_string(System.unique_integer([:positive])),
         {:ok, io} <- File.open(part, [:write, :binary]) do
      {:ok, %{key: key, path: path, part: part, io: io, config: c}}
    end
  end

  @impl Storehouse.Adapter
  def stream_write(%{io: io} = stream, data) do
    :ok = IO.binwrite(io, data)
    {:ok, stream}
  end

  @impl Storehouse.Adapter
  def stream_close(%{io: io, part: part, path: path, key: key, config: c}) do
    with :ok <- File.close(io),
         :ok <- File.rename(part, path) do
      {:ok, url(c, key)}
    end
  end

  @impl Storehouse.Adapter
  def stream_abort(%{io: io, part: part}) do
    _closed = File.close(io)
    _removed = File.rm(part)
    :ok
  end

  @impl Storehouse.Adapter
  def copy(from, to), do: copy(config(), from, to)

  @doc false
  def copy(c, from, to) do
    with {:ok, source} <- path(c, from),
         {:ok, destination} <- path(c, to),
         true <- File.regular?(source) || {:error, :enoent},
         :ok <- File.mkdir_p(Path.dirname(destination)) do
      File.cp(source, destination)
    end
  end

  @impl Storehouse.Adapter
  def checksum(key), do: checksum(config(), key)

  @doc false
  def checksum(c, key) do
    with {:ok, path} <- path(c, key),
         true <- File.regular?(path) || {:error, :enoent} do
      {:ok, Storehouse.checksum(path)}
    end
  end

  @doc false
  # The signature of a request the plug takes: its parts, joined.
  def sign(c, parts) do
    :crypto.mac(:hmac, :sha256, secret(c), Enum.join(parts, "\n"))
    |> Base.url_encode64(padding: false)
  end

  @doc false
  # Whether a request's signature is this store's, for its parts, and it
  # has not expired.
  def signed?(c, parts, expires, signature) when is_binary(signature) do
    with {expires, ""} <- Integer.parse(to_string(expires)),
         true <- expires >= System.system_time(:second) do
      Plug.Crypto.secure_compare(sign(c, parts), signature)
    else
      _other -> false
    end
  end

  def signed?(_c, _parts, _expires, _signature), do: false

  defp secret(c) do
    case Keyword.get(c, :secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        secret

      _missing ->
        raise ArgumentError, """
        Storehouse.Local needs a secret of at least 32 bytes for signed URLs and uploads:

            config :storehouse, Storehouse.Local, secret: System.fetch_env!("STOREHOUSE_SECRET")
        """
    end
  end

  @doc false
  # This store's config; a store of `use Storehouse.Local` has its own.
  def config, do: Application.get_env(:storehouse, __MODULE__, [])
end
