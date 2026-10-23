defmodule Storehouse.Local.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Storehouse.Local.Plug, as: FilePlug

  setup do
    base = Path.join(System.tmp_dir!(), "storehouse-plug-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(Path.join(root, "2026/09"))
    File.write!(Path.join(root, "2026/09/cat.png"), "png bytes")
    File.write!(Path.join(root, "2026/09/page.html"), "<script>alert(1)</script>")
    File.write!(Path.join(root, "2026/09/logo.svg"), "<svg onload=alert(1)/>")
    File.write!(Path.join(root, "2026/09/run.js"), "alert(1)")
    File.write!(Path.join(root, "2026/09/doc.pdf"), "%PDF-1.7")
    File.write!(Path.join(root, "2026/09/notes.txt"), "notes")
    File.write!(Path.join(root, "2026/09/clip.webm"), "0123456789")
    File.write!(Path.join(Path.dirname(root), "secret.txt"), "secret")
    on_exit(fn -> File.rm_rf!(base) end)

    %{root: root, opts: FilePlug.init(at: "/files", root: root, max_age: 60)}
  end

  defp call(method \\ :get, path, opts), do: conn(method, path) |> FilePlug.call(opts)

  test "serves a file with its type and the cache and safety headers", %{opts: opts} do
    conn = call("/files/2026/09/cat.png", opts)

    assert conn.halted
    assert conn.status == 200
    assert conn.resp_body == "png bytes"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
  end

  test "sends an active type as application/octet-stream, as a download", %{opts: opts} do
    for name <- ["page.html", "logo.svg", "run.js"] do
      conn = call("/files/2026/09/#{name}", opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
    end
  end

  test "serves a PDF inline and a text file as a download", %{opts: opts} do
    conn = call("/files/2026/09/doc.pdf", opts)
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]

    conn = call("/files/2026/09/notes.txt", opts)
    assert get_resp_header(conn, "content-type") == ["text/plain"]
    assert get_resp_header(conn, "content-disposition") == ["attachment"]
  end

  test "serves a video inline, and accepts byte ranges", %{opts: opts} do
    conn = call("/files/2026/09/clip.webm", opts)
    assert conn.status == 200
    assert conn.resp_body == "0123456789"
    assert get_resp_header(conn, "content-type") == ["video/webm"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  for {range, status, body, content_range} <- [
        {"bytes=2-5", 206, "2345", "bytes 2-5/10"},
        {"bytes=7-", 206, "789", "bytes 7-9/10"},
        {"bytes=-3", 206, "789", "bytes 7-9/10"},
        {"bytes=8-100", 206, "89", "bytes 8-9/10"},
        {"bytes=-100", 206, "0123456789", "bytes 0-9/10"},
        {"bytes=10-", 416, "", "bytes */10"},
        {"bytes=-0", 416, "", "bytes */10"},
        {"bytes=5-2", 200, "0123456789", nil},
        {"bytes=0-1,4-5", 200, "0123456789", nil},
        {"items=0-1", 200, "0123456789", nil}
      ] do
    test "Range: #{range} gives #{status}", %{opts: opts} do
      conn =
        conn(:get, "/files/2026/09/clip.webm")
        |> put_req_header("range", unquote(range))
        |> FilePlug.call(opts)

      assert conn.status == unquote(status)
      assert conn.resp_body == unquote(body)

      assert get_resp_header(conn, "content-range") ==
               if(unquote(content_range), do: [unquote(content_range)], else: [])
    end
  end

  test "answers HEAD with no body", %{opts: opts} do
    conn = call(:head, "/files/2026/09/cat.png", opts)
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "refuses .. and unsafe segments", %{opts: opts} do
    for path <- [
          "/files/2026/../../secret.txt",
          "/files/..",
          "/files/2026/%2e%2e/x",
          "/files/a%2Fb",
          "/files/a%00b"
        ] do
      conn = call(path, opts)
      assert conn.halted
      assert conn.status == 400, "#{path} gave #{conn.status}"
    end
  end

  test "gives 404 for a missing file, a directory, or the prefix alone", %{opts: opts} do
    assert call("/files/2026/09/none.png", opts).status == 404
    assert call("/files/2026/09", opts).status == 404
    assert call("/files", opts).status == 404
  end

  test "gives 404 for a symbolic link", %{root: root, opts: opts} do
    File.ln_s!(Path.join(Path.dirname(root), "secret.txt"), Path.join(root, "2026/09/link.txt"))
    assert call("/files/2026/09/link.txt", opts).status == 404
  end

  test "gives 404 for a path through a symbolic link to a directory", %{root: root, opts: opts} do
    outside = Path.join(Path.dirname(root), "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(root, "up"))
    File.ln_s!(outside, Path.join(root, "2026/linked"))

    assert call("/files/up/secret.txt", opts).status == 404
    assert call("/files/2026/linked/secret.txt", opts).status == 404
    assert call("/files/2026/09/cat.png", opts).status == 200
  end

  test "serves a file when the root itself is a symbolic link", %{root: root} do
    link = root <> "-link"
    File.ln_s!(root, link)
    on_exit(fn -> File.rm(link) end)

    opts = FilePlug.init(at: "/files", root: link)
    assert call("/files/2026/09/cat.png", opts).status == 200
  end

  test "passes other paths and methods on", %{opts: opts} do
    for conn <- [
          call("/other/cat.png", opts),
          call("/filesx/2026/09/cat.png", opts),
          call(:post, "/files/2026/09/cat.png", opts)
        ] do
      refute conn.halted
      assert conn.status == nil
    end
  end

  test "with at: \"/\", serves the whole path (for a router forward)", %{root: root} do
    conn = call("/2026/09/cat.png", FilePlug.init(at: "/", root: root))
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
  end
end
