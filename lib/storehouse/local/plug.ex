defmodule Storehouse.Local.Plug do
  @moduledoc """
  Serves the files of `Storehouse.Local`, read only.

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
  def init(opts), do: Keyword.validate!(opts, [:at, :root, max_age: 3600])

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    at = split(Keyword.get_lazy(opts, :at, &Local.url_prefix/0))

    case strip(conn.path_info, at) do
      nil -> conn
      segments -> serve(conn, segments, opts)
    end
  end

  def call(conn, _opts), do: conn

  defp split(path), do: String.split(path, "/", trim: true)

  defp strip(path_info, []), do: path_info
  defp strip([segment | path_info], [segment | at]), do: strip(path_info, at)
  defp strip(_path_info, _at), do: nil

  defp serve(conn, [], _opts), do: halt_with(conn, 404)

  defp serve(conn, segments, opts) do
    if Enum.all?(segments, &Storehouse.valid_segment?/1) do
      root = opts |> Keyword.get_lazy(:root, &Local.root/0) |> Path.expand()

      case regular_file(root, segments) do
        {:ok, path, size} -> send_regular_file(conn, path, size, opts)
        :error -> halt_with(conn, 404)
      end
    else
      halt_with(conn, 400)
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
      _other -> :error
    end
  end

  defp send_regular_file(conn, path, size, opts) do
    type = Check.content_type(Path.extname(path))

    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("cache-control", "private, max-age=#{opts[:max_age]}")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("content-disposition", disposition(type))
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

  defp disposition(type), do: if(Check.inline?(type), do: "inline", else: "attachment")

  defp halt_with(conn, status), do: conn |> send_resp(status, "") |> halt()
end
