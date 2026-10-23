defmodule Storehouse.ProxyTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Storehouse.{Memory, Proxy}

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    Memory.checkout()
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory)
    %{original: file, bytes: File.read!(Path.join(@fixtures, "harbour.jpg"))}
  end

  defp proxy(conn, opts \\ []) do
    opts =
      Proxy.init(Keyword.merge([authorize: true, adapter: Memory, chunk_bytes: 10_000], opts))

    Proxy.call(conn, opts)
  end

  defp get(key, headers \\ [], opts \\ []) do
    conn = conn(:get, "/" <> key)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    proxy(conn, opts)
  end

  test "the file, a part at a time, with the safe headers", %{original: file, bytes: bytes} do
    conn = get(file.key)

    assert conn.status == 200
    assert conn.resp_body == bytes
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "content-length") == ["35367"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert get_resp_header(conn, "etag") == [~s("sha256-#{file.checksum}")]
    assert [_last_modified] = get_resp_header(conn, "last-modified")
    assert get_resp_header(conn, "cache-tag") == []
  end

  test "a range of it", %{original: file, bytes: bytes} do
    conn = get(file.key, [{"range", "bytes=100-20099"}])
    assert conn.status == 206
    assert conn.resp_body == binary_part(bytes, 100, 20_000)
    assert get_resp_header(conn, "content-range") == ["bytes 100-20099/35367"]

    conn = get(file.key, [{"range", "bytes=-10"}])
    assert conn.resp_body == binary_part(bytes, 35_357, 10)

    conn = get(file.key, [{"range", "bytes=40000-"}])
    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */35367"]
  end

  test "304 when the browser has it still, and no byte read", %{original: file} do
    etag = ~s("sha256-#{file.checksum}")
    [modified] = file.key |> get() |> get_resp_header("last-modified")

    for headers <- [
          [{"if-none-match", etag}],
          [{"if-none-match", ~s("other", W/#{etag})}],
          [{"if-none-match", "*"}],
          [{"if-modified-since", modified}]
        ] do
      conn = get(file.key, headers)
      assert conn.status == 304, inspect(headers)
      assert conn.resp_body == ""
    end

    assert get(file.key, [{"if-none-match", ~s("other")}]).status == 200
    assert get(file.key, [{"if-modified-since", "Thu, 01 Jan 2015 00:00:00 GMT"}]).status == 200
  end

  test "only for the people the app says may see it, and 404 for the rest", %{original: file} do
    test = self()

    authorize = fn conn, key ->
      send(test, {:asked, key})
      conn.assigns[:person] == :ana
    end

    refused = get(file.key, [], authorize: authorize)
    assert refused.status == 404
    assert refused.resp_body == ""
    assert_received {:asked, key}
    assert key == file.key

    allowed = conn(:get, "/" <> file.key) |> assign(:person, :ana) |> proxy(authorize: authorize)
    assert allowed.status == 200
  end

  test "404 for a key that is not valid, or a file that is not there" do
    assert get("2026/10/none.jpg").status == 404
    assert proxy(conn(:get, "/2026/../secrets.txt")).status == 404
  end

  test "HEAD, and nothing but GET and HEAD", %{original: file} do
    head = proxy(conn(:head, "/" <> file.key))
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == ["35367"]

    assert proxy(conn(:post, "/" <> file.key)).status == 405
  end

  test "a type a browser should not show is a download" do
    path = Path.join(System.tmp_dir!(), "notes-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "Notes.")
    on_exit(fn -> File.rm(path) end)
    {:ok, text} = Storehouse.store(path, adapter: Memory)

    conn = get(text.key)
    assert ["attachment; filename=" <> _] = get_resp_header(conn, "content-disposition")
  end

  test "its cache headers and tag, for a CDN in front", %{original: file} do
    conn =
      get(file.key, [], cache_control: "public, max-age=31536000, immutable", cache_tag: true)

    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "cache-tag") == [Storehouse.Purge.cache_tag(file.key)]
  end

  test "authorize is required" do
    assert_raise ArgumentError, ~r/authorize/, fn -> Proxy.init([]) end
  end
end
