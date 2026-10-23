defmodule Storehouse.TusTest do
  # The tus protocol, request by request, to a store without multipart
  # uploads (the bytes in a file of :dir until the upload is whole).
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Storehouse.Memory
  alias Storehouse.Plug.Presign
  alias Storehouse.Tus.Plug, as: TusPlug

  @fixtures Path.expand("../fixtures", __DIR__)
  @harbour File.read!(Path.join(@fixtures, "harbour.jpg"))

  setup %{tmp_dir: dir} do
    Memory.checkout()
    start_supervised!(Storehouse.Tus)
    test = self()

    opts =
      TusPlug.init(
        adapter: Memory,
        owner: &(&1.assigns[:owner] || "accounts/7"),
        accept: Storehouse.Check.images(),
        max_bytes: 1_000_000,
        dir: dir,
        then: fn conn, file ->
          send(test, {:stored, file})
          put_resp_header(conn, "x-file-key", file.key)
        end
      )

    %{opts: opts, dir: dir}
  end

  @moduletag :tmp_dir

  defp request(method, path, opts, headers \\ [], body \\ "") do
    conn(method, path, body)
    |> put_req_header("tus-resumable", "1.0.0")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, conn -> put_req_header(conn, k, v) end))
    |> TusPlug.call(opts)
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp metadata(pairs),
    do: Enum.map_join(pairs, ",", fn {k, v} -> "#{k} #{Base.encode64(v)}" end)

  defp create(opts, length \\ byte_size(@harbour), extra \\ []) do
    conn =
      request(:post, "/", opts, [
        {"upload-length", "#{length}"},
        {"upload-metadata", metadata(filename: "harbour.jpg", filetype: "image/jpeg")} | extra
      ])

    assert conn.status == 201
    "http://www.example.com/" <> id = header(conn, "location")
    id
  end

  defp patch(opts, id, offset, bytes, headers \\ []) do
    request(
      :patch,
      "/#{id}",
      opts,
      [
        {"content-type", "application/offset+octet-stream"},
        {"upload-offset", "#{offset}"} | headers
      ],
      bytes
    )
  end

  test "its options made once, however many times a server makes them", %{opts: opts} do
    assert TusPlug.init(opts) == opts
    presign = Presign.init(owner: "a", max_bytes: 10)
    assert Presign.init(presign) == presign
  end

  test "what the server takes", %{opts: opts} do
    conn = conn(:options, "/") |> TusPlug.call(opts)

    assert conn.status == 204
    assert header(conn, "tus-version") == "1.0.0"
    assert header(conn, "tus-extension") == "creation,creation-with-upload,termination,expiration"
    assert header(conn, "tus-max-size") == "1000000"
  end

  test "an upload in pieces, its offset asked between them, then stored and checked", %{
    opts: opts,
    dir: dir
  } do
    id = create(opts)
    first = binary_part(@harbour, 0, 10_000)
    rest = binary_part(@harbour, 10_000, byte_size(@harbour) - 10_000)

    conn = patch(opts, id, 0, first)
    assert conn.status == 204
    assert header(conn, "upload-offset") == "10000"

    # Reconnected: the client asks where it was.
    conn = request(:head, "/#{id}", opts)
    assert conn.status == 200
    assert header(conn, "upload-offset") == "10000"
    assert header(conn, "upload-length") == "#{byte_size(@harbour)}"
    assert header(conn, "cache-control") == "no-store"
    assert [_expires] = get_resp_header(conn, "upload-expires")

    conn = patch(opts, id, 10_000, rest)
    assert conn.status == 204
    assert header(conn, "upload-offset") == "#{byte_size(@harbour)}"

    assert_received {:stored, file}
    assert header(conn, "x-file-key") == file.key
    assert "accounts/7/" <> _ = file.key
    assert {file.name, file.content_type, file.width} == {"harbour.jpg", "image/jpeg", 1200}
    assert Storehouse.read(file, adapter: Memory) == {:ok, @harbour}

    # Done: nothing of it is kept.
    assert request(:head, "/#{id}", opts).status == 404
    assert File.ls!(dir) == []
  end

  test "its first bytes with its creation", %{opts: opts} do
    conn =
      request(
        :post,
        "/",
        opts,
        [
          {"upload-length", "#{byte_size(@harbour)}"},
          {"content-type", "application/offset+octet-stream"},
          {"upload-metadata", metadata(filename: "harbour.jpg")}
        ],
        @harbour
      )

    assert conn.status == 201
    assert header(conn, "upload-offset") == "#{byte_size(@harbour)}"
    assert_received {:stored, %{content_type: "image/jpeg"}}
  end

  test "bytes at another offset, of another type, or past its length are refused", %{opts: opts} do
    id = create(opts, 100)

    conn = patch(opts, id, 5, "xx")
    assert conn.status == 409
    assert header(conn, "upload-offset") == "0"

    conn =
      request(
        :patch,
        "/#{id}",
        opts,
        [{"content-type", "text/plain"}, {"upload-offset", "0"}],
        "xx"
      )

    assert conn.status == 415

    assert patch(opts, id, 0, :binary.copy("x", 101)).status == 400
    assert request(:head, "/#{id}", opts) |> header("upload-offset") == "0"
  end

  test "refused before a byte is sent: too large, not a type it takes, no length", %{opts: opts} do
    assert request(:post, "/", opts, [{"upload-length", "1000001"}]).status == 413

    assert request(:post, "/", opts, [
             {"upload-length", "10"},
             {"upload-metadata", metadata(filename: "a.html", filetype: "text/html")}
           ]).status == 415

    assert request(:post, "/", opts, [{"upload-defer-length", "1"}]).status == 400
  end

  test "a file that is not what it said is not kept", %{opts: opts} do
    page = "<html><script>alert(1)</script></html>"
    id = create(opts, byte_size(page))

    assert patch(opts, id, 0, page).status == 422
    refute_received {:stored, _file}
    assert request(:head, "/#{id}", opts).status == 404
  end

  test "another owner's upload is no one's", %{opts: opts} do
    id = create(opts)
    other = fn method, extra -> request(method, "/#{id}", opts, extra) end

    for method <- [:head, :delete] do
      conn =
        conn(method, "/#{id}")
        |> put_req_header("tus-resumable", "1.0.0")
        |> assign(:owner, "accounts/8")

      assert TusPlug.call(conn, opts).status == 404
    end

    assert other.(:head, []).status == 200
  end

  test "given up by the client, and the bytes with it", %{opts: opts, dir: dir} do
    id = create(opts)
    patch(opts, id, 0, "abc")
    assert File.ls!(dir) == [id]

    assert request(:delete, "/#{id}", opts).status == 204
    assert request(:head, "/#{id}", opts).status == 404
    assert File.ls!(dir) == []
  end

  test "an upload that expired is gone, and swept", %{opts: opts, dir: dir} do
    expiring = TusPlug.init(Keyword.merge(opts[:batch], dir: dir, expires_in: -1))
    id = create(expiring)

    assert request(:head, "/#{id}", expiring).status == 410
    assert {:ok, 1} = Storehouse.Tus.sweep()
    assert request(:head, "/#{id}", expiring).status == 404
    assert File.ls!(dir) == []
  end

  test "a request of another version is refused, with the version it takes", %{opts: opts} do
    conn = conn(:post, "/") |> put_req_header("tus-resumable", "0.2.2") |> TusPlug.call(opts)
    assert conn.status == 412
    assert header(conn, "tus-version") == "1.0.0"
  end

  test "one PATCH of an upload at a time", %{opts: opts} do
    id = create(opts)
    lock = {{TusPlug, id}, self()}
    true = :global.set_lock(lock, [node()], 0)

    task = Task.async(fn -> patch(opts, id, 0, "abc").status end)
    assert Task.await(task) == 423
    :global.del_lock(lock, [node()])
  end

  test "one owner's uploads in progress: at most :max_uploads, and within its room", %{
    opts: opts
  } do
    limited =
      Keyword.merge(opts,
        max_uploads: 2,
        room: 1_500,
        batch: Keyword.delete(opts[:batch], :accept)
      )

    first = create(limited, 600)
    _second = create(limited, 600)

    # A third at once is refused, and so is one past the room the others left.
    assert request(:post, "/", limited, [{"upload-length", "100"}]).status == 429
    assert request(:delete, "/#{first}", limited).status == 204
    assert request(:post, "/", limited, [{"upload-length", "1000"}]).status == 413
    assert request(:post, "/", limited, [{"upload-length", "300"}]).status == 201

    # Another owner's are its own.
    conn =
      conn(:post, "/", "")
      |> put_req_header("tus-resumable", "1.0.0")
      |> put_req_header("upload-length", "100")
      |> assign(:owner, "accounts/8")

    assert TusPlug.call(conn, limited).status == 201
  end

  defmodule Parts do
    # A store of multipart uploads that says what was given up, and where.
    def multipart_start(_key, _meta), do: {:ok, "u1"}

    def multipart_put(_key, _id, n, body),
      do: {:ok, %{number: n, etag: "e", bytes: byte_size(body)}}

    def multipart_abort(key, id) do
      send(:tus_sweep_test, {:aborted, key, id})
      :ok
    end
  end

  test "an expired upload is given up in the store it went to, and one that fails stops none" do
    Process.register(self(), :tus_sweep_test)
    # The app's own store is another one, with no multipart uploads.
    opts = TusPlug.init(adapter: Parts, owner: "accounts/7", expires_in: -1)
    id = create(opts, 10)

    assert {:ok, 1} = Storehouse.Tus.sweep()
    assert_received {:aborted, "accounts/7/" <> _, "u1"}
    assert Storehouse.Tus.State.ETS.get(id) == nil

    # One whose store raises: the sweep goes on, and so does the process.
    broken = %{Storehouse.Tus.State.ETS.get(create(opts, 10)) | adapter: :no_such_store}
    Storehouse.Tus.State.ETS.put(broken)
    _other = create(opts, 10)
    pid = Process.whereis(Storehouse.Tus)

    assert {:ok, 2} = Storehouse.Tus.sweep()
    assert_received {:aborted, _key, "u1"}
    send(pid, :sweep)
    assert Process.alive?(pid)
  end
end
