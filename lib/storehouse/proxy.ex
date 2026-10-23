defmodule Storehouse.Proxy do
  @moduledoc """
  A file of the store sent through the app: it checks that the person may
  see it, then streams it from the store, a part at a time, so that the
  bucket's address never leaves the app and a CDN in front keeps what it
  may. The sibling of `Storehouse.Redirect`, which sends the person to a
  signed URL instead.

  In the router, in a scope that has the person:

      forward "/files", Storehouse.Proxy, authorize: &MyAppWeb.Files.allowed?/2

  `/files/2026/10/0b6…-board.png` then sends the file. The function takes
  the conn and the key; a key it refuses, a key that is not valid, or a
  file that is not there, gives `404`, so that no one learns which files
  exist.

  ## Responses

    * The file's type is the store's, through the allow-list of
      `Storehouse.Check.content_type/1`: another is sent as
      `application/octet-stream`. With `X-Content-Type-Options: nosniff`
      and `Content-Security-Policy: default-src 'none'; sandbox`, and
      `Content-Disposition: attachment` for every type a browser should
      not show, as `Storehouse.Local.Plug` sends them.
    * A single `Range` gives `206` with that part, as for
      `Storehouse.Local.Plug`; `Accept-Ranges: bytes` always.
    * `ETag` (from the file's SHA-256, where the store keeps it) and
      `Last-Modified` (where the store says): a request with
      `If-None-Match` or `If-Modified-Since` that still holds gives `304`,
      and no byte is read.

  ## Options

    * `:authorize` - the function (required). `true` lets everyone in: a
      public bucket kept behind the app.
    * `:cache_control` - the `Cache-Control` header. The default is
      `"private, max-age=0, must-revalidate"`: a file only some may see is
      never kept by a CDN for others. For files everyone may see,
      `"public, max-age=31536000, immutable"`.
    * `:cache_tag` - `true` sends the file's `Cache-Tag`
      (`Storehouse.Purge.cache_tag/1`).
    * `:chunk_bytes` - the size of each read from the store. The default
      is 4 MiB.
    * `:adapter` - the store. It must read files a part at a time
      (`c:Storehouse.Adapter.read_range/3`): `Storehouse.Local` and
      `Storehouse.S3` do. The default is `Storehouse.adapter/0`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Storehouse.Check
  alias Storehouse.Plug.Ranges

  @impl Plug
  def init(opts) do
    opts =
      Keyword.validate!(opts, [
        :authorize,
        :adapter,
        cache_control: "private, max-age=0, must-revalidate",
        cache_tag: false,
        chunk_bytes: 4 * 1_048_576
      ])

    case opts[:authorize] do
      fun when is_function(fun, 2) or fun == true ->
        opts

      _other ->
        raise ArgumentError,
              "Storehouse.Proxy needs authorize: a function of the conn and the key, or true"
    end
  end

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    key = Enum.join(conn.path_info, "/")
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)

    with true <- Storehouse.valid_key?(key),
         true <- allowed?(opts[:authorize], conn, key),
         {:ok, head} <- Storehouse.head(key, adapter: adapter) do
      conn
      |> headers(key, head, opts)
      |> respond(key, head, adapter, opts)
      |> halt()
    else
      _refused -> conn |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn |> send_resp(405, "") |> halt()

  defp allowed?(true, _conn, _key), do: true
  defp allowed?(fun, conn, key), do: fun.(conn, key) == true

  defp headers(conn, key, head, opts) do
    type = Check.content_type(Path.extname(key))
    type = if head.content_type in [type, nil], do: type, else: allowed_type(head.content_type)

    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("cache-control", opts[:cache_control])
    |> Storehouse.Purge.put_cache_tag(opts[:cache_tag], key)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("content-disposition", disposition(type, key))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_validators(head)
  end

  # A type the store gives that is not the key's own is kept only when it
  # is one Storehouse checks.
  defp allowed_type(type) do
    if Check.content_type(Check.extension(type)) == type,
      do: type,
      else: "application/octet-stream"
  end

  defp disposition(type, key) do
    if Check.inline?(type),
      do: "inline",
      else: ~s(attachment; filename="#{Path.basename(key)}")
  end

  defp put_validators(conn, head) do
    conn
    |> then(&if(etag = etag(head), do: put_resp_header(&1, "etag", etag), else: &1))
    |> then(fn conn ->
      case head[:modified_at] do
        %DateTime{} = at -> put_resp_header(conn, "last-modified", http_date(at))
        _none -> conn
      end
    end)
  end

  defp etag(%{checksum: checksum}) when is_binary(checksum), do: ~s("sha256-#{checksum}")
  defp etag(_head), do: nil

  defp respond(conn, key, head, adapter, opts) do
    cond do
      not_modified?(conn, head) ->
        send_resp(conn, 304, "")

      conn.method == "HEAD" ->
        conn |> put_resp_header("content-length", "#{head.bytes}") |> send_resp(200, "")

      true ->
        send_range(conn, key, head.bytes, adapter, opts)
    end
  end

  defp not_modified?(conn, head) do
    case get_req_header(conn, "if-none-match") do
      [] -> modified_since?(conn, head[:modified_at])
      tags -> matches?(etag(head), tags)
    end
  end

  # `If-None-Match`: one of its tags, weak or not, or `*`.
  defp matches?(nil, _headers), do: false

  defp matches?(etag, headers) do
    headers
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp modified_since?(conn, %DateTime{} = at) do
    with [since] <- get_req_header(conn, "if-modified-since"),
         {{_, _, _}, {_, _, _}} = erl <-
           :httpd_util.convert_request_date(String.to_charlist(since)),
         {:ok, since} <- DateTime.from_naive(NaiveDateTime.from_erl!(erl), "Etc/UTC") do
      DateTime.compare(DateTime.truncate(at, :second), since) != :gt
    else
      _ -> false
    end
  end

  defp modified_since?(_conn, _at), do: false

  defp send_range(conn, key, size, adapter, opts) do
    case Ranges.range(get_req_header(conn, "range"), size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> stream(206, key, first, last, adapter, opts)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")

      :all when size == 0 ->
        send_resp(conn, 200, "")

      :all ->
        stream(conn, 200, key, 0, size - 1, adapter, opts)
    end
  end

  # The bytes from `first` to `last`, a part at a time: never more than a
  # part in memory.
  defp stream(conn, status, key, first, last, adapter, opts) do
    conn =
      conn |> put_resp_header("content-length", "#{last - first + 1}") |> send_chunked(status)

    first
    |> Stream.iterate(&(&1 + opts[:chunk_bytes]))
    |> Stream.take_while(&(&1 <= last))
    |> Enum.reduce_while(conn, fn from, conn ->
      with {:ok, bytes} <- adapter.read_range(key, from, min(from + opts[:chunk_bytes] - 1, last)),
           {:ok, conn} <- chunk(conn, bytes) do
        {:cont, conn}
      else
        _error -> {:halt, conn}
      end
    end)
  end

  defp http_date(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
end
