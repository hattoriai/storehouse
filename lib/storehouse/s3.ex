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
    * `:cache_control` - the `Cache-Control` the bucket serves each file
      with, kept with it when it is stored, uploaded from the browser,
      streamed in or copied in: for a CDN in front. Keys are never reused,
      so a file never changes: `"public, max-age=31536000, immutable"`.
      The default is none, the bucket's own. A call's `:cache_control`
      takes its place (`Storehouse.store/2`).
    * `:if_none_match` - whether an upload straight to the bucket is
      signed with `If-None-Match: *`, so the bucket takes it only where no
      file is: its URL cannot replace a file once it was checked. The
      default is `true`; AWS S3, R2 and MinIO take it. Set it to `false`
      for a store that refuses the header.

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
        "AllowedHeaders": ["content-type", "content-disposition", "if-none-match"],
        "MaxAgeSeconds": 3600}]

  The URL writes only where no file is (`If-None-Match: *`): once the
  file was checked (`Storehouse.verify_upload/2`), the same URL cannot
  put other bytes in its place.

  An upload presigned with its checksum (`:checksum`) is signed with
  `x-amz-checksum-sha256` too, and the bucket refuses bytes that do not
  have it: add it and `x-amz-sdk-checksum-algorithm` to `AllowedHeaders`.
  A store with a `:cache_control` signs it too: add `cache-control`.
  """

  @behaviour Storehouse.Adapter

  @doc """
  Defines a store of its own, with a config of its own: a second bucket
  beside the first (public and private files, media on R2, files kept in
  another region).

      defmodule MyApp.PrivateFiles, do: use Storehouse.S3

      config :storehouse, MyApp.PrivateFiles, bucket: "acme-private", region: "eu-west-1", …

  The module is a `Storehouse.Adapter`: give it as `adapter:` (or a field's
  `store:`, `Storehouse.Ecto.File`). With `otp_app: :my_app`, its config is
  `config :my_app, MyApp.PrivateFiles, …`.
  """
  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app, :storehouse)

    quote do
      @behaviour Storehouse.Adapter

      @doc false
      def config, do: Application.get_env(unquote(otp_app), __MODULE__, [])

      @doc false
      # What the store is, for a copy made in the store itself (`Storehouse.copy/2`).
      def __store__, do: {Storehouse.S3, config()}

      @impl true
      def put(key, path, meta), do: Storehouse.S3.put(config(), key, path, meta)
      @impl true
      def url(key), do: Storehouse.S3.url(config(), key)
      @impl true
      def delete(key), do: Storehouse.S3.delete(config(), key)
      @impl true
      def presign_upload(key, meta, opts),
        do: Storehouse.S3.presign_upload(config(), key, meta, opts)

      @impl true
      def signed_url(key, opts), do: Storehouse.S3.signed_url(config(), key, opts)
      @impl true
      def read_head(key, bytes), do: Storehouse.S3.read_head(config(), key, bytes)
      @impl true
      def head(key), do: Storehouse.S3.head(config(), key)
      @impl true
      def read_range(key, first, last), do: Storehouse.S3.read_range(config(), key, first, last)
      @impl true
      def list(prefix), do: Storehouse.S3.list(config(), prefix)
      @impl true
      def list(prefix, opts), do: Storehouse.S3.list(config(), prefix, opts)
      @impl true
      def delete_many(keys), do: Storehouse.S3.delete_many(config(), keys)
      @impl true
      def copy(from, to), do: Storehouse.S3.copy(config(), from, to)
      @impl true
      def checksum(key), do: Storehouse.S3.checksum(config(), key)
      @impl true
      def stream_open(key, meta), do: Storehouse.S3.stream_open(config(), key, meta)
      # A stream carries its store's config.
      @impl true
      def stream_write(stream, data), do: Storehouse.S3.stream_write(stream, data)
      @impl true
      def stream_close(stream), do: Storehouse.S3.stream_close(stream)
      @impl true
      def stream_abort(stream), do: Storehouse.S3.stream_abort(stream)
      @impl true
      def multipart_start(key, meta), do: Storehouse.S3.multipart_start(config(), key, meta)
      @impl true
      def multipart_sign(key, upload_id, number, opts),
        do: Storehouse.S3.multipart_sign(config(), key, upload_id, number, opts)

      @impl true
      def multipart_put(key, upload_id, number, body),
        do: Storehouse.S3.multipart_put(config(), key, upload_id, number, body)

      @impl true
      def multipart_parts(key, upload_id),
        do: Storehouse.S3.multipart_parts(config(), key, upload_id)

      @impl true
      def multipart_complete(key, upload_id, parts),
        do: Storehouse.S3.multipart_complete(config(), key, upload_id, parts)

      @impl true
      def multipart_abort(key, upload_id),
        do: Storehouse.S3.multipart_abort(config(), key, upload_id)

      @impl true
      def multipart_uploads(prefix), do: Storehouse.S3.multipart_uploads(config(), prefix)
    end
  end

  alias Storehouse.Check
  alias Storehouse.S3.{Parts, Signature}

  @impl Storehouse.Adapter
  def put(key, path, meta), do: put(config(), key, path, meta)

  @doc false
  def put(c, key, path, meta) do
    with {:ok, uri} <- object_uri(c, key),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      type = Map.get(meta, :content_type, "application/octet-stream")

      # With its checksum, the bucket refuses a file that is not the one sent.
      headers =
        [
          {"content-type", type},
          {"content-disposition", disposition(type)},
          {"content-length", Integer.to_string(size)}
        ] ++
          cache_header(c, meta) ++
          if(meta[:checksum],
            do: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", meta.checksum}
            ],
            else: []
          )

      case request(c, :put, uri, headers, {:file, path, size}) do
        {:ok, status, _headers, _body} when status in 200..299 -> {:ok, url(c, key)}
        {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def url(key), do: url(config(), key)

  @doc false
  def url(c, key) do
    case c[:public_url] do
      base when is_binary(base) -> String.trim_trailing(base, "/") <> "/" <> key
      nil -> c |> base_uri(key) |> URI.to_string()
    end
  end

  @impl Storehouse.Adapter
  def delete(key), do: delete(config(), key)

  @doc false
  def delete(c, key) do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :delete, uri, [], nil) do
        {:ok, status, _headers, _body} when status in 200..299 or status == 404 -> :ok
        {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def presign_upload(key, meta, opts), do: presign_upload(config(), key, meta, opts)

  @doc false
  def presign_upload(c, key, meta, opts) do
    with {:ok, uri} <- object_uri(c, key) do
      type = Map.fetch!(meta, :content_type)

      headers =
        %{"content-type" => type, "content-disposition" => disposition(type)}
        |> Map.merge(checksum_headers(meta[:checksum]))
        |> Map.merge(Map.new(cache_header(c, meta)))
        |> Map.merge(once_header(c))

      # The size is signed too: the bucket takes the file of that size only.
      signed =
        Signature.presign("PUT", uri, Keyword.get(opts, :expires_in, 600), credentials(c),
          headers:
            Map.to_list(headers) ++
              [{"content-length", Integer.to_string(Map.fetch!(meta, :bytes))}]
        )

      {:ok, %{method: "PUT", url: URI.to_string(signed), headers: headers}}
    end
  end

  # The Cache-Control the file is served with: the call's, else the store's.
  defp cache_header(c, meta) do
    case meta[:cache_control] || c[:cache_control] do
      nil -> []
      value -> [{"cache-control", value}]
    end
  end

  # Only where no file is: the URL never replaces the file it put there.
  defp once_header(c),
    do: if(Keyword.get(c, :if_none_match, true), do: %{"if-none-match" => "*"}, else: %{})

  # With a checksum, the bucket takes only the bytes that have it.
  defp checksum_headers(nil), do: %{}

  defp checksum_headers(checksum),
    do: %{"x-amz-checksum-sha256" => checksum, "x-amz-sdk-checksum-algorithm" => "SHA256"}

  @impl Storehouse.Adapter
  def signed_url(key, opts), do: signed_url(config(), key, opts)

  @doc false
  def signed_url(c, key, opts) do
    with {:ok, uri} <- object_uri(c, key) do
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
          credentials(c)
        )

      {:ok, URI.to_string(signed)}
    end
  end

  @impl Storehouse.Adapter
  def read_head(key, bytes), do: read_head(config(), key, bytes)

  @doc false
  def read_head(c, key, bytes) do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :get, uri, [{"range", "bytes=0-#{bytes - 1}"}], nil) do
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
  def head(key), do: head(config(), key)

  @doc false
  def head(c, key) do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :head, uri, [{"x-amz-checksum-mode", "ENABLED"}], nil) do
        {:ok, 200, headers, _body} ->
          {:ok,
           %{
             bytes: headers |> header("content-length", "0") |> String.to_integer(),
             content_type: header(headers, "content-type", nil),
             checksum: header(headers, "x-amz-checksum-sha256", nil),
             modified_at: headers |> header("last-modified", nil) |> http_date()
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
  def read_range(key, first, last), do: read_range(config(), key, first, last)

  @doc false
  def read_range(c, key, first, last) when first >= 0 and last >= first do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :get, uri, [{"range", "bytes=#{first}-#{last}"}], nil) do
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
  def list(prefix), do: list(config(), prefix, [])

  @impl Storehouse.Adapter
  # The bucket starts after the key itself (`start-after`). With a config
  # first, the store's own listing.
  def list(prefix, opts) when is_binary(prefix), do: list(config(), prefix, opts)
  def list(c, prefix) when is_list(c), do: list(c, prefix, [])

  @doc false
  def list(c, prefix, opts) do
    first = {:first, Keyword.get(opts, :after)}
    {:ok, Stream.resource(fn -> first end, &list_page(c, prefix, &1), fn _token -> :ok end)}
  end

  defp list_page(_c, _prefix, :done), do: {:halt, :done}

  defp list_page(c, prefix, token) do
    params =
      case token do
        {:first, nil} -> %{"list-type" => "2", "prefix" => prefix}
        {:first, start} -> %{"list-type" => "2", "prefix" => prefix, "start-after" => start}
        token -> %{"list-type" => "2", "prefix" => prefix, "continuation-token" => token}
      end

    case request(c, :get, query(bucket_uri(c), params), [], nil) do
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

  # An HTTP date (`Wed, 21 Oct 2026 07:28:00 GMT`), as a DateTime, or nil.
  defp http_date(nil), do: nil

  defp http_date(text) do
    case :httpd_util.convert_request_date(String.to_charlist(text)) do
      {{_, _, _}, {_, _, _}} = erl ->
        erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")

      _bad_date ->
        nil
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
  def delete_many(keys), do: delete_many(config(), keys)

  @doc false
  def delete_many(_c, []), do: :ok

  def delete_many(c, keys) when length(keys) <= 1_000 do
    body =
      "<Delete><Quiet>true</Quiet>" <>
        Enum.map_join(keys, "", &"<Object><Key>#{escape(&1)}</Key></Object>") <>
        "</Delete>"

    headers = [
      {"content-type", "application/xml"},
      {"content-md5", Base.encode64(:crypto.hash(:md5, body))}
    ]

    case request(c, :post, query(bucket_uri(c), %{"delete" => ""}), headers, body) do
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

  defp bucket_uri(c), do: %{base_uri(c, "") | query: nil}

  defp header(headers, name, default) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> default
    end
  end

  # A multipart upload straight from the browser (Storehouse.presign_multipart/4):
  # started here, each part signed for the browser's PUT with its
  # checksum, its parts listed back from the bucket, completed with
  # those, never with what the browser says.
  @impl Storehouse.Adapter
  def multipart_start(key, meta), do: multipart_start(config(), key, meta)

  @doc false
  def multipart_start(c, key, meta) do
    with {:ok, uri} <- object_uri(c, key) do
      type = Map.get(meta, :content_type, "application/octet-stream")

      headers =
        object_headers(type) ++ cache_header(c, meta) ++ [{"x-amz-checksum-algorithm", "SHA256"}]

      case request(c, :post, query(uri, %{"uploads" => ""}), headers, nil) do
        {:ok, 200, _headers, body} ->
          upload_id(body)

        {:ok, status, _headers, body} ->
          {:error, {:s3, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp upload_id(body) do
    case tag(body, "UploadId") do
      "" -> {:error, {:s3, 200, body}}
      id -> {:ok, unescape(id)}
    end
  end

  @impl Storehouse.Adapter
  def multipart_sign(key, upload_id, number, opts),
    do: multipart_sign(config(), key, upload_id, number, opts)

  @doc false
  def multipart_sign(c, key, upload_id, number, opts) do
    with {:ok, uri} <- object_uri(c, key) do
      uri = query(uri, %{"partNumber" => Integer.to_string(number), "uploadId" => upload_id})

      headers =
        if checksum = opts[:checksum], do: %{"x-amz-checksum-sha256" => checksum}, else: %{}

      # With its size, the bucket takes a part of that size only.
      length =
        if bytes = opts[:bytes], do: [{"content-length", Integer.to_string(bytes)}], else: []

      signed =
        Signature.presign("PUT", uri, Keyword.get(opts, :expires_in, 3_600), credentials(c),
          headers: Map.to_list(headers) ++ length
        )

      {:ok, %{method: "PUT", url: URI.to_string(signed), headers: headers}}
    end
  end

  @impl Storehouse.Adapter
  def multipart_put(key, upload_id, number, body),
    do: multipart_put(config(), key, upload_id, number, body)

  @doc false
  def multipart_put(c, key, upload_id, number, body) do
    with {:ok, uri} <- object_uri(c, key),
         {:ok, {^number, etag, checksum}} <-
           upload_part(%{config: c, uri: uri, upload_id: upload_id}, number, body) do
      {:ok, %{number: number, etag: etag, bytes: byte_size(body), checksum: checksum}}
    end
  end

  @impl Storehouse.Adapter
  def multipart_parts(key, upload_id), do: multipart_parts(config(), key, upload_id)

  @doc false
  def multipart_parts(c, key, upload_id) do
    with {:ok, uri} <- object_uri(c, key), do: parts_from(c, uri, upload_id, nil, [])
  end

  # ListParts, a page of a thousand at a time.
  defp parts_from(c, uri, upload_id, marker, acc) do
    params = %{"uploadId" => upload_id}
    params = if marker, do: Map.put(params, "part-number-marker", marker), else: params

    case request(c, :get, query(uri, params), [], nil) do
      {:ok, 200, _headers, body} ->
        parts =
          for [_all, part] <- Regex.scan(~r{<Part>(.*?)</Part>}s, body) do
            %{
              number: part |> tag("PartNumber") |> String.to_integer(),
              etag: part |> tag("ETag") |> unescape(),
              bytes: part |> tag("Size") |> String.to_integer(),
              checksum: part |> tag("ChecksumSHA256") |> then(&if(&1 == "", do: nil, else: &1))
            }
          end

        acc = acc ++ parts

        if tag(body, "IsTruncated") == "true",
          do: parts_from(c, uri, upload_id, tag(body, "NextPartNumberMarker"), acc),
          else: {:ok, acc}

      {:ok, 404, _headers, _body} ->
        {:error, :enoent}

      {:ok, status, _headers, body} ->
        {:error, {:s3, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Storehouse.Adapter
  def multipart_complete(key, upload_id, parts),
    do: multipart_complete(config(), key, upload_id, parts)

  @doc false
  def multipart_complete(c, key, upload_id, parts) do
    with {:ok, uri} <- object_uri(c, key) do
      complete(%{
        config: c,
        uri: uri,
        upload_id: upload_id,
        parts: Enum.map(parts, &{&1.number, &1.etag, &1.checksum})
      })
    end
  end

  @impl Storehouse.Adapter
  def multipart_abort(key, upload_id), do: multipart_abort(config(), key, upload_id)

  @doc false
  def multipart_abort(c, key, upload_id) do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :delete, query(uri, %{"uploadId" => upload_id}), [], nil) do
        {:ok, status, _headers, _body} when status in 200..299 or status == 404 -> :ok
        {:ok, status, _headers, body} -> {:error, {:s3, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storehouse.Adapter
  def multipart_uploads(prefix), do: multipart_uploads(config(), prefix)

  @doc false
  # The multipart uploads started under a prefix and not completed, a page
  # at a time: for the sweeper, as abandoned ones keep their parts.
  def multipart_uploads(c, prefix), do: uploads_from(c, prefix, nil, [])

  defp uploads_from(c, prefix, markers, acc) do
    params = %{"uploads" => "", "prefix" => prefix}

    params =
      case markers do
        {key, id} -> Map.merge(params, %{"key-marker" => key, "upload-id-marker" => id})
        nil -> params
      end

    case request(c, :get, query(bucket_uri(c), params), [], nil) do
      {:ok, 200, _headers, body} ->
        uploads =
          for [_all, upload] <- Regex.scan(~r{<Upload>(.*?)</Upload>}s, body) do
            %{
              key: upload |> tag("Key") |> unescape(),
              upload_id: upload |> tag("UploadId") |> unescape(),
              started_at: upload |> tag("Initiated") |> modified_at()
            }
          end

        acc = acc ++ uploads

        if tag(body, "IsTruncated") == "true",
          do:
            uploads_from(
              c,
              prefix,
              {unescape(tag(body, "NextKeyMarker")), unescape(tag(body, "NextUploadIdMarker"))},
              acc
            ),
          else: {:ok, acc}

      {:ok, status, _headers, body} ->
        {:error, {:s3, status, body}}

      {:error, reason} ->
        {:error, reason}
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
  def stream_open(key, meta), do: stream_open(config(), key, meta)

  @doc false
  def stream_open(c, key, meta) do
    with {:ok, uri} <- object_uri(c, key) do
      type = Map.get(meta, :content_type, "application/octet-stream")
      part_size = max(Keyword.get(c, :part_size, 8 * 1_048_576), @min_part)

      {:ok,
       %{
         key: key,
         uri: uri,
         type: type,
         cache: cache_header(c, meta),
         part_size: part_size,
         buffer: [],
         size: 0,
         upload_id: nil,
         part: 0,
         parts: [],
         sender: nil,
         config: c
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
    c = stream.config
    body = IO.iodata_to_binary(stream.buffer)

    headers =
      object_headers(stream.type) ++
        stream.cache ++
        [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", Base.encode64(Signature.sha256(body))}
        ]

    case request(c, :put, stream.uri, headers, body) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        {:ok, url(stream.config, stream.key)}

      {:ok, status, _headers, body} ->
        {:error, {:s3, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream_close(stream) do
    with {:ok, stream} <- if(stream.size > 0, do: send_part(stream), else: {:ok, stream}),
         {:ok, parts} <- Parts.finish(stream.sender),
         :ok <- complete(%{stream | parts: parts}) do
      Parts.stop(stream.sender)
      {:ok, url(stream.config, stream.key)}
    else
      {:error, reason} ->
        stream_abort(stream)
        {:error, reason}
    end
  end

  @impl Storehouse.Adapter
  def stream_abort(stream) do
    c = stream.config
    if stream.sender, do: Parts.stop(stream.sender)

    if stream.upload_id do
      _result = request(c, :delete, query(stream.uri, %{"uploadId" => stream.upload_id}), [], nil)
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
    c = stream.config

    headers =
      object_headers(stream.type) ++ stream.cache ++ [{"x-amz-checksum-algorithm", "SHA256"}]

    case request(c, :post, query(stream.uri, %{"uploads" => ""}), headers, nil) do
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
    c = stream.config
    checksum = Base.encode64(Signature.sha256(body))

    uri =
      query(stream.uri, %{"partNumber" => Integer.to_string(n), "uploadId" => stream.upload_id})

    case request(c, :put, uri, [{"x-amz-checksum-sha256", checksum}], body) do
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
    c = stream.config

    parts =
      Enum.map_join(stream.parts, "", fn {n, etag, checksum} ->
        sum = if checksum, do: "<ChecksumSHA256>#{checksum}</ChecksumSHA256>", else: ""
        "<Part><PartNumber>#{n}</PartNumber><ETag>#{escape(etag)}</ETag>#{sum}</Part>"
      end)

    body = "<CompleteMultipartUpload>#{parts}</CompleteMultipartUpload>"
    uri = query(stream.uri, %{"uploadId" => stream.upload_id})

    # As a copy, a completion can fail after its 200.
    case request(c, :post, uri, [{"content-type", "application/xml"}], body) do
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
  def copy(from, to), do: copy(config(), from, to)

  @doc false
  def copy(c, from, to), do: copy_between(c, from, c, to)

  @doc false
  # A copy from one bucket to another the same credentials reach, in S3
  # (CopyObject, for a file of up to 5 GB): no byte goes through the app.
  def copy_between(from_c, from, c, to) do
    with {:ok, _from} <- object_uri(from_c, from),
         {:ok, uri} <- object_uri(c, to) do
      source =
        "/#{Keyword.fetch!(from_c, :bucket)}/" <>
          Enum.map_join(String.split(from, "/"), "/", &Signature.encode/1)

      # A copy can fail after its 200: the error is then in the body.
      with {:ok, headers} <- copy_headers(from_c, from, c, source) do
        copied(request(c, :put, uri, headers, nil))
      end
    end
  end

  # The copy keeps the original's headers, unless the store it goes to
  # serves its files with a Cache-Control of its own: then they are
  # written again, with it.
  defp copy_headers(from_c, from, c, source) do
    case c[:cache_control] do
      nil ->
        {:ok, [{"x-amz-copy-source", source}]}

      cache_control ->
        with {:ok, %{content_type: type}} <- head(from_c, from) do
          type = type || "application/octet-stream"

          {:ok,
           [
             {"x-amz-copy-source", source},
             {"x-amz-metadata-directive", "REPLACE"},
             {"x-amz-checksum-algorithm", "SHA256"},
             {"cache-control", cache_control}
             | object_headers(type)
           ]}
        end
    end
  end

  defp copied({:ok, 200, _headers, body}), do: error_in_body(body)
  defp copied({:ok, 404, _headers, _body}), do: {:error, :enoent}
  defp copied({:ok, status, _headers, body}), do: {:error, {:s3, status, body}}
  defp copied({:error, reason}), do: {:error, reason}

  @doc false
  # Whether a copy from one store's bucket to another's can be made in S3:
  # the same endpoint, region and credentials.
  def same_account?(from_c, c) do
    Enum.all?([:endpoint, :region, :access_key_id, :secret_access_key, :session_token], fn key ->
      from_c[key] == c[key]
    end)
  end

  defp error_in_body(body), do: if(body =~ "<Error>", do: {:error, {:s3, 200, body}}, else: :ok)

  @impl Storehouse.Adapter
  def checksum(key), do: checksum(config(), key)

  @doc false
  def checksum(c, key) do
    with {:ok, uri} <- object_uri(c, key) do
      case request(c, :head, uri, [{"x-amz-checksum-mode", "ENABLED"}], nil) do
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

  defp object_uri(c, key) do
    if Storehouse.valid_key?(key), do: {:ok, base_uri(c, key)}, else: {:error, :invalid_key}
  end

  defp base_uri(c, key) do
    config = c
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

  defp credentials(c) do
    config = c

    %{
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      region: Keyword.fetch!(config, :region),
      session_token: config[:session_token]
    }
  end

  @doc false
  # This store's config; a store of `use Storehouse.S3` has its own.
  def config, do: Application.get_env(:storehouse, __MODULE__, [])

  @doc false
  def __store__, do: {__MODULE__, config()}

  # A signed request, with Req. A file's body is streamed from the disk.
  defp request(c, method, uri, headers, body) do
    signed =
      Signature.sign_headers(
        method |> Atom.to_string() |> String.upcase(),
        uri,
        headers,
        credentials(c)
      )

    # The host is the connection's; the size, the body's.
    request_headers = for {k, v} <- signed, k not in ["host", "content-length"], do: {k, v}

    request_headers =
      if List.keymember?(request_headers, "content-type", 0),
        do: request_headers,
        else: [{"content-type", "application/octet-stream"} | request_headers]

    {request_headers, body} =
      case body do
        # A PUT or POST without a body says so: a copy, a multipart start.
        nil when method in [:put, :post] ->
          {request_headers, ""}

        {:file, path, size} ->
          {[{"content-length", Integer.to_string(size)} | request_headers], {:file, path}}

        body ->
          {request_headers, body}
      end

    Storehouse.HTTP.request(method, URI.to_string(uri), request_headers, body)
  end
end
