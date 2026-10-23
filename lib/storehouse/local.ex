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

  @default_prefix "/uploads"

  @impl Storehouse.Adapter
  def put(key, path, _meta) do
    with {:ok, destination} <- path(key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(path, destination) do
      {:ok, url(key)}
    end
  end

  @impl Storehouse.Adapter
  def url(key) when is_binary(key), do: String.trim_trailing(url_prefix(), "/") <> "/" <> key

  @impl Storehouse.Adapter
  def delete(key) do
    with {:ok, path} <- path(key) do
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
  def path(key) do
    root = root()

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
  def root do
    case Keyword.get(config(), :root) do
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
  def url_prefix, do: Keyword.get(config(), :url_prefix, @default_prefix)

  @impl Storehouse.Adapter
  def presign_upload(key, meta, opts) do
    with {:ok, _path} <- path(key) do
      expires = System.system_time(:second) + Keyword.get(opts, :expires_in, 600)
      type = Map.fetch!(meta, :content_type)
      bytes = Map.fetch!(meta, :bytes)
      signature = sign(["PUT", key, expires, type, bytes])

      query =
        URI.encode_query(%{
          "expires" => expires,
          "type" => type,
          "bytes" => bytes,
          "signature" => signature
        })

      {:ok, %{method: "PUT", url: url(key) <> "?" <> query, headers: %{"content-type" => type}}}
    end
  end

  @impl Storehouse.Adapter
  def signed_url(key, opts) do
    with {:ok, _path} <- path(key) do
      expires = System.system_time(:second) + Keyword.get(opts, :expires_in, 300)
      disposition = disposition(opts)

      params =
        %{"expires" => expires, "signature" => sign(["GET", key, expires, disposition])}
        |> then(&if disposition == "", do: &1, else: Map.put(&1, "disposition", disposition))

      {:ok, url(key) <> "?" <> URI.encode_query(params)}
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
  def read_head(key, bytes) do
    with {:ok, path} <- path(key),
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

  @impl Storehouse.Adapter
  def checksum(key) do
    with {:ok, path} <- path(key),
         true <- File.regular?(path) || {:error, :enoent} do
      {:ok, Storehouse.checksum(path)}
    end
  end

  @doc false
  # The signature of a request the plug takes: its parts, joined.
  def sign(parts) do
    :crypto.mac(:hmac, :sha256, secret(), Enum.join(parts, "\n"))
    |> Base.url_encode64(padding: false)
  end

  @doc false
  # Whether a request's signature is this store's, for its parts, and it
  # has not expired.
  def signed?(parts, expires, signature) when is_binary(signature) do
    with {expires, ""} <- Integer.parse(to_string(expires)),
         true <- expires >= System.system_time(:second) do
      Plug.Crypto.secure_compare(sign(parts), signature)
    else
      _other -> false
    end
  end

  def signed?(_parts, _expires, _signature), do: false

  defp secret do
    case Keyword.get(config(), :secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        secret

      _missing ->
        raise ArgumentError, """
        Storehouse.Local needs a secret of at least 32 bytes for signed URLs and uploads:

            config :storehouse, Storehouse.Local, secret: System.fetch_env!("STOREHOUSE_SECRET")
        """
    end
  end

  defp config, do: Application.get_env(:storehouse, __MODULE__, [])
end
