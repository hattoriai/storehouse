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
  alias Storehouse.S3.{Parts, Signature}

  @impl Storehouse.Adapter
  def put(key, path, meta) do
    with {:ok, uri} <- object_uri(key),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      type = Map.get(meta, :content_type, "application/octet-stream")

      # With its checksum, the bucket refuses a file that is not the one sent.
      headers =
        [
          {"content-type", type},
          {"content-disposition", disposition(type)},
          {"content-length", Integer.to_string(size)}
        ] ++
          if(meta[:checksum],
            do: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", meta.checksum}
            ],
            else: []
          )

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

  @impl Storehouse.Adapter
  def head(key) do
    with {:ok, uri} <- object_uri(key) do
      case request(:head, uri, [{"x-amz-checksum-mode", "ENABLED"}], nil) do
        {:ok, 200, headers, _body} ->
          {:ok,
           %{
             bytes: headers |> header("content-length", "0") |> String.to_integer(),
             content_type: header(headers, "content-type", nil),
             checksum: header(headers, "x-amz-checksum-sha256", nil)
           }}

        {:ok, 404, _headers, _body} ->
          {:error, :enoent}

        {:ok, status, _headers, body} ->
          {:error, {:s3, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def read_range(key, first, last) when first >= 0 and last >= first do
    with {:ok, uri} <- object_uri(key) do
      case request(:get, uri, [{"range", "bytes=#{first}-#{last}"}], nil) do
        {:ok, 206, _headers, body} ->
          {:ok, body}

        # A store that sends the whole file, for a range it does not take.
        {:ok, 200, _headers, body} when first >= byte_size(body) ->
          {:ok, ""}

        {:ok, 200, _headers, body} ->
          {:ok, binary_part(body, first, min(last - first + 1, byte_size(body) - first))}

        # Past the end of the file.
        {:ok, 416, _headers, _body} ->
          {:ok, ""}

        {:ok, 404, _headers, _body} ->
          {:error, :enoent}

        {:ok, status, _headers, body} ->
          {:error, {:s3, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A page of ListObjectsV2 at a time, as the stream is taken.
  @impl Storehouse.Adapter
  def list(prefix) do
    {:ok, Stream.resource(fn -> :first end, &list_page(prefix, &1), fn _token -> :ok end)}
  end

  defp list_page(_prefix, :done), do: {:halt, :done}

  defp list_page(prefix, token) do
    params =
      %{"list-type" => "2", "prefix" => prefix}
      |> then(&if token == :first, do: &1, else: Map.put(&1, "continuation-token", token))

    case request(:get, query(bucket_uri(), params), [], nil) do
      {:ok, 200, _headers, body} ->
        {listed(body), next_token(body)}

      {:ok, status, _headers, body} ->
        raise Storehouse.ReadError, key: prefix, reason: {:s3, status, body}

      {:error, reason} ->
        raise Storehouse.ReadError, key: prefix, reason: reason
    end
  end

  defp listed(body) do
    for [_all, contents] <- Regex.scan(~r{<Contents>(.*?)</Contents>}s, body) do
      %{
        key: contents |> tag("Key") |> unescape(),
        bytes: contents |> tag("Size") |> String.to_integer(),
        modified_at: contents |> tag("LastModified") |> modified_at()
      }
    end
  end

  defp next_token(body) do
    if tag(body, "IsTruncated") == "true",
      do: unescape(tag(body, "NextContinuationToken")),
      else: :done
  end

  defp tag(xml, name) do
    case Regex.run(~r{<#{name}>(.*?)</#{name}>}s, xml) do
      [_all, value] -> value
      nil -> ""
    end
  end

  defp modified_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> DateTime.from_unix!(0)
    end
  end

  defp unescape(text),
    do:
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")

  # DeleteObjects, quietly: the answer names only the keys not deleted.
  @impl Storehouse.Adapter
  def delete_many([]), do: :ok

  def delete_many(keys) when length(keys) <= 1_000 do
    body =
      "<Delete><Quiet>true</Quiet>" <>
        Enum.map_join(keys, "", &"<Object><Key>#{escape(&1)}</Key></Object>") <>
        "</Delete>"

    headers = [
      {"content-type", "application/xml"},
      {"content-md5", Base.encode64(:crypto.hash(:md5, body))}
    ]

    case request(:post, query(bucket_uri(), %{"delete" => ""}), headers, body) do
      {:ok, 200, _headers, answer} ->
        case Regex.scan(~r{<Error>.*?<Key>(.*?)</Key>.*?</Error>}s, answer) do
          [] ->
            :ok

          errors ->
            {:error, {:not_deleted, Enum.map(errors, fn [_all, key] -> unescape(key) end)}}
        end

      {:ok, status, _headers, answer} ->
        {:error, {:s3, status, answer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bucket_uri, do: %{base_uri("") | query: nil}

  defp header(headers, name, default) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> default
    end
  end

  # An upload streamed through the app (Storehouse.Live.allow/3, mode:
  # :stream): its bytes, in parts of a multipart upload as they come, with
  # at most two parts on their way at once while the next ones arrive; a
  # file smaller than a part, in one PUT. Each part has its checksum,
  # which the bucket checks.

  @min_part 5 * 1_048_576
  @in_flight 2

  @impl Storehouse.Adapter
  def stream_open(key, meta) do
    with {:ok, uri} <- object_uri(key) do
      type = Map.get(meta, :content_type, "application/octet-stream")
      part_size = max(Keyword.get(config(), :part_size, 8 * 1_048_576), @min_part)

      {:ok,
       %{
         key: key,
         uri: uri,
         type: type,
         part_size: part_size,
         buffer: [],
         size: 0,
         upload_id: nil,
         part: 0,
         parts: [],
         sender: nil
       }}
    end
  end

  @impl Storehouse.Adapter
  def stream_write(stream, data) do
    stream = %{stream | buffer: [stream.buffer, data], size: stream.size + IO.iodata_length(data)}
    if stream.size >= stream.part_size, do: send_part(stream), else: {:ok, stream}
  end

  @impl Storehouse.Adapter
  def stream_close(%{upload_id: nil} = stream) do
    body = IO.iodata_to_binary(stream.buffer)

    headers =
      object_headers(stream.type) ++
        [{"x-amz-checksum-sha256", Base.encode64(Signature.sha256(body))}]

    case request(:put, stream.uri, headers, body) do
      {:ok, status, _headers, _body} when status in 200..299 -> {:ok, url(stream.key)}
      {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def stream_close(stream) do
    with {:ok, stream} <- if(stream.size > 0, do: send_part(stream), else: {:ok, stream}),
         {:ok, parts} <- Parts.finish(stream.sender),
         :ok <- complete(%{stream | parts: parts}) do
      Parts.stop(stream.sender)
      {:ok, url(stream.key)}
    else
      {:error, reason} ->
        stream_abort(stream)
        {:error, reason}
    end
  end

  @impl Storehouse.Adapter
  def stream_abort(stream) do
    if stream.sender, do: Parts.stop(stream.sender)

    if stream.upload_id do
      _result = request(:delete, query(stream.uri, %{"uploadId" => stream.upload_id}), [], nil)
    end

    :ok
  end

  defp object_headers(type),
    do: [{"content-type", type}, {"content-disposition", disposition(type)}]

  defp send_part(stream) do
    with {:ok, stream} <- start_multipart(stream) do
      body = IO.iodata_to_binary(stream.buffer)
      n = stream.part + 1

      case Parts.put(stream.sender, n, body) do
        :ok -> {:ok, %{stream | buffer: [], size: 0, part: n}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_multipart(%{upload_id: nil} = stream) do
    headers = object_headers(stream.type) ++ [{"x-amz-checksum-algorithm", "SHA256"}]

    case request(:post, query(stream.uri, %{"uploads" => ""}), headers, nil) do
      {:ok, 200, _headers, body} ->
        case Regex.run(~r{<UploadId>([^<]+)</UploadId>}, body) do
          [_, id] ->
            upload = &upload_part(%{stream | upload_id: id}, &1, &2)
            {:ok, sender} = Parts.start(upload, @in_flight)
            {:ok, %{stream | upload_id: id, sender: sender}}

          nil ->
            {:error, {:s3, 200, body}}
        end

      {:ok, status, _headers, body} ->
        {:error, {:s3, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_multipart(stream), do: {:ok, stream}

  defp upload_part(stream, n, body) do
    checksum = Base.encode64(Signature.sha256(body))

    uri =
      query(stream.uri, %{"partNumber" => Integer.to_string(n), "uploadId" => stream.upload_id})

    case request(:put, uri, [{"x-amz-checksum-sha256", checksum}], body) do
      {:ok, 200, headers, _body} ->
        {_name, etag} = List.keyfind(headers, "etag", 0, {"etag", ""})
        {:ok, {n, etag, checksum}}

      {:ok, status, _headers, body} ->
        {:error, {:s3, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete(stream) do
    parts =
      Enum.map_join(stream.parts, "", fn {n, etag, checksum} ->
        "<Part><PartNumber>#{n}</PartNumber><ETag>#{escape(etag)}</ETag><ChecksumSHA256>#{checksum}</ChecksumSHA256></Part>"
      end)

    body = "<CompleteMultipartUpload>#{parts}</CompleteMultipartUpload>"
    uri = query(stream.uri, %{"uploadId" => stream.upload_id})

    # As a copy, a completion can fail after its 200.
    case request(:post, uri, [{"content-type", "application/xml"}], body) do
      {:ok, 200, _headers, response} ->
        if response =~ "<Error>", do: {:error, {:s3, 200, response}}, else: :ok

      {:ok, status, _headers, response} ->
        {:error, {:s3, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(uri, params), do: %{uri | query: URI.encode_query(params, :rfc3986)}

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  @impl Storehouse.Adapter
  def copy(from, to) do
    with {:ok, _from} <- object_uri(from),
         {:ok, uri} <- object_uri(to) do
      source =
        "/#{Keyword.fetch!(config(), :bucket)}/" <>
          Enum.map_join(String.split(from, "/"), "/", &Signature.encode/1)

      # A copy can fail after its 200: the error is then in the body.
      case request(:put, uri, [{"x-amz-copy-source", source}], nil) do
        {:ok, 200, _headers, body} ->
          error_in_body(body)

        {:ok, 404, _headers, _body} ->
          {:error, :enoent}

        {:ok, status, _headers, body} ->
          {:error, {:s3, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp error_in_body(body), do: if(body =~ "<Error>", do: {:error, {:s3, 200, body}}, else: :ok)

  @impl Storehouse.Adapter
  def checksum(key) do
    with {:ok, uri} <- object_uri(key) do
      case request(:head, uri, [{"x-amz-checksum-mode", "ENABLED"}], nil) do
        {:ok, 200, headers, _body} ->
          {:ok, headers |> List.keyfind("x-amz-checksum-sha256", 0) |> then(&(&1 && elem(&1, 1)))}

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
        nil when method in [:put, :post] ->
          {url, request_headers, ~c"application/octet-stream", ""}

        nil ->
          {url, request_headers}

        body when is_binary(body) ->
          {url, request_headers, String.to_charlist(type), body}

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
