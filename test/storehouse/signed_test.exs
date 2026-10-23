defmodule Storehouse.SignedTest do
  # Signed URLs and uploads straight to the store, with the local store
  # and its plug, and lasting URLs that redirect to signed ones.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Storehouse.Local.Plug, as: FilePlug

  @fixtures Path.expand("../fixtures", __DIR__)
  @secret String.duplicate("storehouse-test-secret-", 2)

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-signed-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Storehouse.Local, root: root, secret: @secret)

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{root: root, public: FilePlug.init([]), private: FilePlug.init(private: true)}
  end

  defp send(method, url, opts, body \\ "", headers \\ []) do
    headers
    |> Enum.reduce(conn(method, url, body), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> FilePlug.call(opts)
  end

  defp put_file(upload, body, opts, type \\ nil) do
    send(:put, upload.url, opts, body, [{"content-type", type || upload.headers["content-type"]}])
  end

  describe "an upload straight to the local store" do
    test "signed with its checksum takes only those bytes", %{root: root, public: opts} do
      data = File.read!(Path.join(@fixtures, "harbour.jpg"))
      checksum = Base.encode64(:crypto.hash(:sha256, data))

      {:ok, upload} =
        Storehouse.presign_upload("Quay.jpg", "image/jpeg", byte_size(data), checksum: checksum)

      other = binary_part(data, 0, byte_size(data) - 1) <> "x"
      assert put_file(upload, other, opts).status == 400
      refute File.exists?(Path.join(root, upload.key))

      # The checksum is signed: another in the URL is refused.
      forged = String.replace(upload.url, URI.encode_www_form(checksum), "AAAA")
      assert send(:put, forged, opts, data, [{"content-type", "image/jpeg"}]).status == 403

      assert put_file(upload, data, opts).status == 200
      assert File.read!(Path.join(root, upload.key)) == data
    end

    test "two writes of one key at once: the first stays", %{root: root} do
      key = "2026/10/0b6f4c2e-5f0a-4d4c-9a51-2f0e7d1c3b9a-a.png"
      config = Storehouse.Local.config()

      # Both began before either was done: neither saw a file there.
      {:ok, first} = Storehouse.Local.stream_open(config, key, %{})
      {:ok, second} = Storehouse.Local.stream_open(config, key, %{})
      {:ok, first} = Storehouse.Local.stream_write(first, "checked")
      {:ok, second} = Storehouse.Local.stream_write(second, "never!!")

      assert {:ok, _url} = Storehouse.Local.stream_close(first)
      assert {:error, :eexist} = Storehouse.Local.stream_close(second)
      assert File.read!(Path.join(root, key)) == "checked"
      assert File.ls!(Path.dirname(Path.join(root, key))) == [Path.basename(key)]
    end

    test "is taken at the URL it signed, of its type and size, once", %{root: root, public: opts} do
      data = File.read!(Path.join(@fixtures, "harbour.jpg"))
      assert {:ok, upload} = Storehouse.presign_upload("Quay.jpg", "image/jpeg", byte_size(data))
      assert %{method: "PUT", key: key, headers: %{"content-type" => "image/jpeg"}} = upload
      assert key =~ ~r/-Quay\.jpg\z/

      assert put_file(upload, data, opts).status == 200
      assert File.read!(Path.join(root, key)) == data
      # Once: the key has its file.
      assert put_file(upload, data, opts).status == 409

      assert {:ok, file} = Storehouse.verify_upload(key, name: "Quay.jpg")
      assert file.checksum == Base.encode64(:crypto.hash(:sha256, data))

      assert %Storehouse.File{
               name: "Quay.jpg",
               content_type: "image/jpeg",
               width: 1200,
               height: 800
             } = file

      assert file.url == "/uploads/" <> key
    end

    test "is refused at another size, another type, another key, or late", %{
      root: root,
      public: opts
    } do
      data = File.read!(Path.join(@fixtures, "small.png"))
      {:ok, upload} = Storehouse.presign_upload("a.png", "image/png", byte_size(data))

      assert put_file(upload, data <> "more", opts).status == 400
      assert put_file(upload, binary_part(data, 0, 10), opts).status == 400
      assert put_file(upload, data, opts, "text/html").status == 400

      assert send(:put, String.replace(upload.url, "a.png", "b.png"), opts, data, [
               {"content-type", "image/png"}
             ]).status == 403

      assert send(:put, String.replace(upload.url, "signature=", "signature=x"), opts, data, [
               {"content-type", "image/png"}
             ]).status == 403

      {:ok, late} =
        Storehouse.presign_upload("a.png", "image/png", byte_size(data), expires_in: -1)

      assert put_file(late, data, opts).status == 403

      assert Path.wildcard(Path.join(root, "**/*")) |> Enum.filter(&File.regular?/1) == []
    end

    test "is checked when it is there: a page sent as a PNG goes", %{root: root, public: opts} do
      page = "<html><script>alert(1)</script></html>"
      {:ok, upload} = Storehouse.presign_upload("a.png", "image/png", byte_size(page))
      assert put_file(upload, page, opts).status == 200

      assert {:error, :not_accepted} = Storehouse.verify_upload(upload.key)
      refute File.exists?(Path.join(root, upload.key))
    end

    test "is temporary with cache: true, until it is made permanent", %{root: root, public: opts} do
      data = File.read!(Path.join(@fixtures, "small.png"))

      {:ok, upload} =
        Storehouse.presign_upload("a.png", "image/png", byte_size(data), cache: true)

      assert String.starts_with?(upload.key, "cache/")
      assert put_file(upload, data, opts).status == 200

      {:ok, file} = Storehouse.verify_upload(upload.key)
      assert Storehouse.cached?(file)
      {:ok, file} = Storehouse.promote(file)
      refute Storehouse.cached?(file)
      assert File.exists?(Path.join(root, file.key))
      refute File.exists?(Path.join(root, upload.key))
    end

    test "is refused before it starts: a type not taken, a file too large" do
      assert {:error, :not_accepted} =
               Storehouse.presign_upload("a.pdf", "application/pdf", 10,
                 accept: Storehouse.Check.images()
               )

      assert {:error, :too_large} =
               Storehouse.presign_upload("a.png", "image/png", 10_001, max_bytes: 10_000)

      # A type the store does not know goes as a download, with a .bin key.
      assert {:ok, %{key: key}} = Storehouse.presign_upload("page.html", "text/html", 10)
      assert String.ends_with?(key, ".bin")
    end

    test "needs a store that signs uploads" do
      defmodule Plain do
        def put(_key, _path, _meta), do: {:ok, "/x"}
        def url(key), do: "/" <> key
        def delete(_key), do: :ok
      end

      assert {:error, :not_supported} =
               Storehouse.presign_upload("a.png", "image/png", 1, adapter: Plain)

      assert {:error, :not_supported} = Storehouse.signed_url("2026/10/a.png", adapter: Plain)
    end
  end

  describe "a signed URL" do
    setup %{root: root} do
      File.mkdir_p!(Path.join(root, "2026/10"))
      File.cp!(Path.join(@fixtures, "small.png"), Path.join(root, "2026/10/a.png"))
      File.write!(Path.join(root, "2026/10/page.bin"), "<script>alert(1)</script>")
      :ok
    end

    test "is the only way to a file of a private store, until it expires", %{private: opts} do
      assert send(:get, "/uploads/2026/10/a.png", opts).status == 403

      {:ok, url} = Storehouse.signed_url("2026/10/a.png")
      conn = send(:get, url, opts)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]

      {:ok, late} = Storehouse.signed_url("2026/10/a.png", expires_in: -1)
      assert send(:get, late, opts).status == 403
      assert send(:get, String.replace(url, "a.png", "b.png"), opts).status == 403
    end

    test "a private store's file is never for a shared cache, nor past its URL" do
      # Even with a public Cache-Control, meant for a CDN in front.
      opts = FilePlug.init(private: true, cache_control: "public, max-age=31536000, immutable")

      {:ok, url} = Storehouse.signed_url("2026/10/a.png", expires_in: 60)
      [cache] = get_resp_header(send(:get, url, opts), "cache-control")
      assert "private, max-age=" <> left = cache
      assert String.to_integer(left) in 58..60

      {:ok, url} = Storehouse.signed_url("2026/10/a.png", expires_in: 86_400)
      assert get_resp_header(send(:get, url, opts), "cache-control") == ["private, max-age=3600"]
    end

    test "names a download, and never shows inline what a browser should not", %{public: opts} do
      {:ok, url} = Storehouse.signed_url("2026/10/a.png", filename: "Small board.png")

      assert get_resp_header(send(:get, url, opts), "content-disposition") == [
               ~s(attachment; filename="Small board.png")
             ]

      {:ok, url} = Storehouse.signed_url("2026/10/page.bin", disposition: "inline")
      assert get_resp_header(send(:get, url, opts), "content-disposition") == ["attachment"]

      # Its disposition is signed: another is refused.
      assert send(:get, String.replace(url, "inline", "attachment"), opts).status == 403
    end

    test "needs the store's secret" do
      Application.put_env(:storehouse, Storehouse.Local, root: "tmp", secret: "short")

      assert_raise ArgumentError, ~r/needs a secret/, fn ->
        Storehouse.signed_url("2026/10/a.png")
      end
    end
  end

  describe "Storehouse.Redirect" do
    setup %{root: root} do
      File.mkdir_p!(Path.join(root, "2026/10"))
      File.cp!(Path.join(@fixtures, "small.png"), Path.join(root, "2026/10/a.png"))
      :ok
    end

    defp redirect(path, authorize) do
      opts = Storehouse.Redirect.init(authorize: authorize)

      conn(:get, path)
      |> Map.put(
        :path_info,
        path |> URI.parse() |> Map.get(:path) |> String.split("/", trim: true)
      )
      |> Storehouse.Redirect.call(opts)
    end

    test "redirects to a signed URL of a file the person may see, and to nothing else", %{
      private: opts
    } do
      conn = redirect("/2026/10/a.png", fn _conn, key -> key == "2026/10/a.png" end)
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert send(:get, location, opts).status == 200

      assert redirect("/2026/10/b.png", fn _conn, key -> key == "2026/10/a.png" end).status == 404
      assert redirect("/2026/../a.png", true).status == 404
    end

    test "asks for a download" do
      [location] = get_resp_header(redirect("/2026/10/a.png?download=1", true), "location")
      assert location =~ "disposition=attachment"
    end

    test "needs a way to authorize" do
      assert_raise ArgumentError, fn -> Storehouse.Redirect.init([]) end
    end
  end
end
