defmodule Storehouse.Local.Plug do
  @moduledoc """
  Serves the files of `Storehouse.Local`, and takes the ones a browser
  uploads straight to it, when the store signed the upload.

  In the endpoint, before the router:

      plug Storehouse.Local.Plug

  The plug answers `GET` and `HEAD` requests under the `:at` path (by
  default the configured `:url_prefix` of `Storehouse.Local`), and
  passes every other request on. In a router, `forward` strips the path, so
  give `at: "/"`:

      forward "/uploads", Storehouse.Local.Plug, at: "/"

  ## Options

    * `:at` - the request path of the files. The default is the configured
      `:url_prefix`.
    * `:root` - the directory. The default is the configured `:root`.
    * `:max_age` - the `max-age` of the `Cache-Control` header, in seconds.
      The default is `3600`.
    * `:private` - when `true`, a file is served only at a URL the store
      signed (`Storehouse.signed_url/2`), until it expires. The default is
      `false`: every file is served, and a signed URL as well.

  ## Uploads

  A `PUT` of a file at a URL the store signed (`Storehouse.presign_upload/4`)
  writes it under its key: of the signed type (its `Content-Type`), of the
  signed size exactly, before the signature expires, and only where no
  file is. The answer is `200`; `403` for a signature that is not the
  store's or has expired, `409` for a key that has a file, `400` for a
  body of another size or type. Put the plug before `Plug.Parsers`, which
  would read the body first.

  ## Responses

    * The content type comes from the file extension, through the allow-list
      of `Storehouse.Check.content_type/1`: an extension that is not in it
      (`.html`, `.svg`, …) is sent as `application/octet-stream`.
    * `Cache-Control: private, max-age=…`, `X-Content-Type-Options: nosniff`
      and `Content-Security-Policy: default-src 'none'; sandbox`, so a file
      cannot run a script on the app's origin.
    * PNG, JPEG, GIF and WebP images, PDF files and MP4 and WebM videos
      are served inline; every other file has
      `Content-Disposition: attachment`.
    * `Accept-Ranges: bytes`, and a `GET` with a single `Range`
      (`bytes=0-99`, `bytes=100-`, `bytes=-100`) gives `206` with that part
      of the file and `Content-Range`. A range that starts after the end of
      the file gives `416`. Several ranges, or a header that is not valid,
      give the whole file. Browsers need ranges to seek in a video, and
      Safari to play one.
    * A path with a segment that is not a valid key segment (`..`, `.`, or
      a character other than ASCII letters, digits, `.`, `-` and `_`) gives
      `400`. A key with no regular file gives `404`: a directory, a symbolic
      link to a file, and a path through a symbolic link to a directory
      included.
  """

  @behaviour Plug

  import Plug.Conn

  alias Storehouse.{Check, Local}

  @impl Plug
  def init(opts), do: Keyword.validate!(opts, [:at, :root, max_age: 3600, private: false])

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD", "PUT"] do
    at = split(Keyword.get_lazy(opts, :at, &Local.url_prefix/0))

    case strip(conn.path_info, at) do
      nil -> conn
      segments when method == "PUT" -> upload(fetch_query_params(conn), segments, opts)
      segments -> serve(fetch_query_params(conn), segments, opts)
    end
  end

  def call(conn, _opts), do: conn

  defp split(path), do: String.split(path, "/", trim: true)

  defp strip(path_info, []), do: path_info
  defp strip([segment | path_info], [segment | at]), do: strip(path_info, at)
  defp strip(_path_info, _at), do: nil

  defp serve(conn, [], _opts), do: halt_with(conn, 404)

  defp serve(conn, segments, opts) do
    with true <- Enum.all?(segments, &Storehouse.valid_segment?/1) || 400,
         {:ok, disposition} <- signed_get(conn, Enum.join(segments, "/"), opts[:private]),
         root = opts |> Keyword.get_lazy(:root, &Local.root/0) |> Path.expand(),
         {:ok, path, size} <- regular_file(root, segments) || 404 do
      send_regular_file(conn, path, size, disposition, opts)
    else
      status when is_integer(status) -> halt_with(conn, status)
    end
  end

  # A URL the store signed: its disposition, or the type's. With no
  # signature, a file of a store that is not private.
  defp signed_get(%{query_params: %{"signature" => signature} = params}, key, _private) do
    disposition = Map.get(params, "disposition", "")

    if Local.signed?(["GET", key, params["expires"], disposition], params["expires"], signature),
      do: {:ok, if(disposition == "", do: nil, else: disposition)},
      else: 403
  end

  defp signed_get(_conn, _key, true), do: 403
  defp signed_get(_conn, _key, _private), do: {:ok, nil}

  defp upload(conn, segments, opts) do
    key = Enum.join(segments, "/")
    params = conn.query_params
    type = params["type"]

    with true <- Enum.all?(segments, &Storehouse.valid_segment?/1) || 400,
         true <-
           Local.signed?(
             ["PUT", key, params["expires"], type, params["bytes"]] ++
               List.wrap(params["checksum"]),
             params["expires"],
             params["signature"]
           ) ||
             403,
         {bytes, ""} <- Integer.parse(params["bytes"]),
         true <- content_type(conn) == type || 400,
         root = opts |> Keyword.get_lazy(:root, &Local.root/0) |> Path.expand(),
         {:ok, path} <- Local.path(key),
         true <- String.starts_with?(path, root <> "/") || 400,
         false <- File.exists?(path) && 409,
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- receive_file(conn, path, bytes, params["checksum"]) do
      conn |> send_resp(200, "") |> halt()
    else
      status when is_integer(status) -> halt_with(conn, status)
      {:error, conn, status} -> halt_with(conn, status)
      _other -> halt_with(conn, 400)
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [type | _rest] -> type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  # The body, to a file beside the key's, then in its place: of `bytes`
  # bytes exactly, and of the checksum signed, when one was, as S3 checks
  # it (a 400 then, as S3's BadDigest).
  defp receive_file(conn, path, bytes, checksum) do
    part = path <> ".part-" <> Integer.to_string(System.unique_integer([:positive]))

    case File.open(part, [:write, :binary], &read_into(conn, &1, bytes, 0)) do
      {:ok, {:ok, conn, ^bytes}} ->
        with true <- is_nil(checksum) or Storehouse.checksum(part) == checksum,
             :ok <- File.rename(part, path) do
          {:ok, conn}
        else
          false -> discard(part, conn, 400)
          {:error, _reason} -> discard(part, conn, 500)
        end

      {:ok, {:ok, conn, _other}} ->
        discard(part, conn, 400)

      {:ok, {:error, conn}} ->
        discard(part, conn, 400)

      {:error, _reason} ->
        {:error, conn, 500}
    end
  end

  defp discard(part, conn, status) do
    File.rm(part)
    {:error, conn, status}
  end

  defp write_chunk(conn, file, chunk, state, bytes, size) do
    :ok = IO.binwrite(file, chunk)
    if state == :ok, do: {:ok, conn, size}, else: read_into(conn, file, bytes, size)
  end

  defp read_into(conn, file, bytes, size) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {state, chunk, conn} when state in [:ok, :more] ->
        size = size + byte_size(chunk)

        if size > bytes,
          do: {:error, conn},
          else: write_chunk(conn, file, chunk, state, bytes, size)

      {:error, _reason} ->
        {:error, conn}
    end
  end

  # Each directory under the root must be a real directory and the last
  # segment a regular file: a symbolic link at any level gives :error.
  defp regular_file(root, segments) do
    {directories, [file]} = Enum.split(segments, -1)

    directory =
      Enum.reduce_while(directories, root, fn segment, parent ->
        path = Path.join(parent, segment)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> {:cont, path}
          _other -> {:halt, nil}
        end
      end)

    with directory when is_binary(directory) <- directory,
         path = Path.join(directory, file),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path) do
      {:ok, path, size}
    else
      _other -> nil
    end
  end

  defp send_regular_file(conn, path, size, disposition, opts) do
    type = Check.content_type(Path.extname(path))

    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("cache-control", "private, max-age=#{opts[:max_age]}")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("content-disposition", disposition(type, disposition))
    |> put_resp_header("accept-ranges", "bytes")
    |> send_body(path, size)
    |> halt()
  end

  defp send_body(%Plug.Conn{method: "HEAD"} = conn, _path, _size), do: send_resp(conn, 200, "")

  defp send_body(conn, path, size) do
    case range(get_req_header(conn, "range"), size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      :all ->
        send_file(conn, 200, path)
    end
  end

  # One `bytes` range: `first-last`, `first-` or `-suffix`. Anything else
  # (several ranges, another unit, a header that is not valid) is the whole
  # file, as RFC 9110 allows.
  defp range([header], size) do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, String.trim(header), capture: :all_but_first) do
      ["", ""] -> :all
      ["", suffix] -> suffix_range(String.to_integer(suffix), size)
      [first, last] -> first_range(String.to_integer(first), last, size)
      nil -> :all
    end
  end

  defp range(_headers, _size), do: :all

  defp suffix_range(0, _size), do: :unsatisfiable
  defp suffix_range(_suffix, 0), do: :unsatisfiable
  defp suffix_range(suffix, size), do: {max(size - suffix, 0), size - 1}

  defp first_range(first, _last, size) when first >= size, do: :unsatisfiable
  defp first_range(first, "", size), do: {first, size - 1}

  defp first_range(first, last, size) do
    case String.to_integer(last) do
      last when last < first -> :all
      last -> {first, min(last, size - 1)}
    end
  end

  # The type's, or a signed URL's: a download with its name, or inline for
  # a type a browser shows, and never inline for another.
  defp disposition(type, nil), do: if(Check.inline?(type), do: "inline", else: "attachment")

  defp disposition(type, "inline" <> rest) do
    if Check.inline?(type), do: "inline" <> rest, else: "attachment" <> rest
  end

  defp disposition(_type, signed), do: signed

  defp halt_with(conn, status), do: conn |> send_resp(status, "") |> halt()
end
