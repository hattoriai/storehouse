defmodule Storehouse.S3 do
  @moduledoc """
  A `Storehouse.Adapter` for Amazon S3, and the stores that speak its API:
  Cloudflare R2, MinIO, Tigris, Backblaze B2, DigitalOcean Spaces, Google
  Cloud Storage's interoperability. With no dependency: it signs its
  requests itself (AWS Signature Version 4).

      # config/runtime.exs
      config :storehouse, adapter: Storehouse.S3

      config :storehouse, Storehouse.S3,
        bucket: "my-app-uploads",
        region: "eu-west-1",
        access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")

  For another store, its `endpoint` (whose URLs name the bucket in the
  path, `path_style`, unless told otherwise):

      config :storehouse, Storehouse.S3,
        bucket: "uploads",
        region: "auto",
        endpoint: "https://<account>.r2.cloudflarestorage.com",
        access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY"),
        public_url: "https://files.example.com"

  ## Options

    * `:bucket`, `:region`, `:access_key_id`, `:secret_access_key`
      (required), and `:session_token` for temporary credentials.
    * `:endpoint` - the store's URL. The default is AWS's,
      `https://s3.<region>.amazonaws.com`.
    * `:path_style` - whether URLs name the bucket in their path
      (`https://endpoint/bucket/key`) rather than their host
      (`https://bucket.endpoint/key`). The default is `false` for AWS,
      `true` with an `:endpoint`.
    * `:public_url` - the base URL of the files for `url/1`: a CDN, a
      custom domain. The default is the bucket's URL. A bucket that is not
      public serves its files at signed URLs (`Storehouse.signed_url/2`).

  Each file is stored with its checked content type, and with
  `Content-Disposition: attachment` for every type a browser should not
  show (`Storehouse.Check.inline?/1`): the store never serves an
  uploaded page as a page.

  ## Uploads straight to the bucket

  `presign_upload/3` signs a `PUT` of one file, of its type and its size
  exactly, which the browser sends to the bucket without going through
  the app (`Storehouse.Live.allow/3`). The bucket must allow it with CORS:

      [{"AllowedOrigins": ["https://my-app.example.com"],
        "AllowedMethods": ["PUT"],
        "AllowedHeaders": ["content-type", "content-disposition"],
        "MaxAgeSeconds": 3600}]
  """

  @behaviour Storehouse.Adapter

  alias Storehouse.Check
  alias Storehouse.S3.Signature

  @impl Storehouse.Adapter
  def put(key, path, meta) do
    with {:ok, uri} <- object_uri(key),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      type = Map.get(meta, :content_type, "application/octet-stream")

      headers = [
        {"content-type", type},
        {"content-disposition", disposition(type)},
        {"content-length", Integer.to_string(size)}
      ]

      case request(:put, uri, headers, {:file, path, size}) do
        {:ok, status, _headers, _body} when status in 200..299 -> {:ok, url(key)}
        {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def url(key) do
    case config()[:public_url] do
      base when is_binary(base) -> String.trim_trailing(base, "/") <> "/" <> key
      nil -> key |> base_uri() |> URI.to_string()
    end
  end

  @impl Storehouse.Adapter
  def delete(key) do
    with {:ok, uri} <- object_uri(key) do
      case request(:delete, uri, [], nil) do
        {:ok, status, _headers, _body} when status in 200..299 or status == 404 -> :ok
        {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def presign_upload(key, meta, opts) do
    with {:ok, uri} <- object_uri(key) do
      type = Map.fetch!(meta, :content_type)
      headers = %{"content-type" => type, "content-disposition" => disposition(type)}

      # The size is signed too: the bucket takes the file of that size only.
      signed =
        Signature.presign("PUT", uri, Keyword.get(opts, :expires_in, 600), credentials(),
          headers:
            Map.to_list(headers) ++
              [{"content-length", Integer.to_string(Map.fetch!(meta, :bytes))}]
        )

      {:ok, %{method: "PUT", url: URI.to_string(signed), headers: headers}}
    end
  end

  @impl Storehouse.Adapter
  def signed_url(key, opts) do
    with {:ok, uri} <- object_uri(key) do
      query =
        case disposition_param(opts) do
          nil -> nil
          disposition -> URI.encode_query(%{"response-content-disposition" => disposition})
        end

      signed =
        Signature.presign(
          "GET",
          %{uri | query: query},
          Keyword.get(opts, :expires_in, 300),
          credentials()
        )

      {:ok, URI.to_string(signed)}
    end
  end

  @impl Storehouse.Adapter
  def read_head(key, bytes) do
    with {:ok, uri} <- object_uri(key) do
      case request(:get, uri, [{"range", "bytes=0-#{bytes - 1}"}], nil) do
        {:ok, 206, headers, body} ->
          {:ok, body, total(headers, byte_size(body))}

        {:ok, 200, _headers, body} ->
          {:ok, binary_part(body, 0, min(bytes, byte_size(body))), byte_size(body)}

        # An empty file has no range.
        {:ok, 416, _headers, _body} ->
          {:ok, "", 0}

        {:ok, 404, _headers, _body} ->
          {:error, :enoent}

        {:ok, status, _headers, body} ->
          {:error, {:s3, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # `Content-Range: bytes 0-262143/1048576`: the size of the whole file.
  defp total(headers, default) do
    with {_name, value} <- List.keyfind(headers, "content-range", 0),
         [_, size] <- Regex.run(~r{/(\d+)\z}, value) do
      String.to_integer(size)
    else
      _other -> default
    end
  end

  defp disposition(type), do: if(Check.inline?(type), do: "inline", else: "attachment")

  defp disposition_param(opts) do
    case {opts[:disposition], opts[:filename]} do
      {nil, nil} ->
        nil

      {kind, nil} ->
        to_string(kind)

      {kind, name} ->
        ~s(#{kind || "attachment"}; filename="#{String.replace(name, ~r/[^A-Za-z0-9._\- ]/, "_")}")
    end
  end

  defp object_uri(key) do
    if Storehouse.valid_key?(key), do: {:ok, base_uri(key)}, else: {:error, :invalid_key}
  end

  defp base_uri(key) do
    config = config()
    bucket = Keyword.fetch!(config, :bucket)

    endpoint =
      URI.parse(
        config[:endpoint] || "https://s3.#{Keyword.fetch!(config, :region)}.amazonaws.com"
      )

    path_style = Keyword.get(config, :path_style, config[:endpoint] != nil)
    path = Enum.map_join(String.split(key, "/"), "/", &Signature.encode/1)
    base = String.trim_trailing(endpoint.path || "", "/")

    if path_style,
      do: %{endpoint | path: "#{base}/#{bucket}/#{path}"},
      else: %{endpoint | host: "#{bucket}.#{endpoint.host}", path: "#{base}/#{path}"}
  end

  defp credentials do
    config = config()

    %{
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      region: Keyword.fetch!(config, :region),
      session_token: config[:session_token]
    }
  end

  defp config, do: Application.get_env(:storehouse, __MODULE__, [])

  # A signed request, with :httpc. A file's body is streamed from the disk.
  defp request(method, uri, headers, body) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    signed =
      Signature.sign_headers(
        method |> Atom.to_string() |> String.upcase(),
        uri,
        headers,
        credentials()
      )

    url = String.to_charlist(URI.to_string(uri))

    request_headers =
      for {k, v} <- signed,
          k not in ["host", "content-type", "content-length"],
          do: {String.to_charlist(k), String.to_charlist(v)}

    type =
      signed
      |> List.keyfind("content-type", 0)
      |> then(&if &1, do: elem(&1, 1), else: "application/octet-stream")

    request =
      case body do
        nil ->
          {url, request_headers}

        {:file, path, size} ->
          {url, [{~c"content-length", Integer.to_charlist(size)} | request_headers],
           String.to_charlist(type), {&stream_file/1, {path, nil}}}
      end

    http_opts = [timeout: 60_000, connect_timeout: 10_000, ssl: ssl()]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        {:ok, status,
         Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end), body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # :httpc's body function: the file, a megabyte at a time.
  defp stream_file({path, nil}) do
    {:ok, file} = File.open(path, [:read, :binary])
    stream_file({path, file})
  end

  defp stream_file({path, file}) do
    case IO.binread(file, 1_048_576) do
      data when is_binary(data) ->
        {:ok, data, {path, file}}

      _eof ->
        File.close(file)
        :eof
    end
  end

  defp ssl do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
