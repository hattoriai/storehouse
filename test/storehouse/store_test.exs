defmodule Storehouse.StoreTest do
  # Files stored as they are uploaded, and fetched from an address: with
  # the local store, whose root is application config.
  use ExUnit.Case, async: false

  doctest Storehouse

  @fixtures Path.expand("../fixtures", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-store-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Storehouse.Local, root: root)

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  describe "an image" do
    test "has its size, and a JPEG's is turned as its EXIF says" do
      assert {:ok, %Storehouse.File{content_type: "image/png", width: 4, height: 3}} =
               Storehouse.store(fixture("small.png"))

      assert {:ok, %{content_type: "image/gif", width: 5, height: 7}} =
               Storehouse.store(fixture("small.gif"))

      assert {:ok, %{content_type: "image/webp", width: 6, height: 2}} =
               Storehouse.store(fixture("small.webp"))

      # 8 × 6, with the orientation 6: a quarter turn.
      assert {:ok, %{content_type: "image/jpeg", width: 6, height: 8}} =
               Storehouse.store(fixture("turned.jpg"))
    end

    test "is stored under its key, in the local store", %{root: root} do
      assert {:ok, file} = Storehouse.store(fixture("harbour.jpg"), name: "The quay.jpeg")
      assert Storehouse.File.image?(file)
      assert file.key =~ ~r"\A\d{4}/\d{2}/[0-9a-f-]{36}-The_quay\.jpg\z"
      assert file.url == "/uploads/" <> file.key
      assert Storehouse.url(file.key) == file.url
      assert File.read!(Path.join(root, file.key)) == File.read!(fixture("harbour.jpg"))

      assert :ok = Storehouse.delete(file.key)
      refute File.exists?(Path.join(root, file.key))
    end
  end

  describe "a checksum" do
    test "is the SHA-256 of the bytes, kept with the file", %{root: root} do
      path = fixture("harbour.jpg")
      sha = path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

      assert Storehouse.checksum(path) == sha
      assert {:ok, %{checksum: ^sha, key: key}} = Storehouse.store(path)
      assert Storehouse.checksum(Path.join(root, key)) == sha
      assert {:ok, ^sha} = Storehouse.Local.checksum(key)
    end
  end

  describe "the limits" do
    test "refuse a file too large, an image of too many pixels, a type not taken", %{root: root} do
      assert {:error, :too_large} = Storehouse.store(fixture("harbour.jpg"), max_bytes: 1_000)
      assert {:error, :too_large} = Storehouse.store(fixture("harbour.jpg"), max_pixels: 10_000)

      assert {:error, :not_accepted} =
               Storehouse.store(fixture("not-an-image.png"), accept: Storehouse.Check.images())

      assert {:ok, _file} =
               Storehouse.store(fixture("small.png"), accept: Storehouse.Check.images())

      assert Path.wildcard(Path.join(root, "**/*.{jpg,bin}")) == []
    end
  end

  describe "a preview" do
    test "is the app's URL, and none when it fails" do
      assert {:ok, %{preview: "/previews/" <> _}} =
               Storehouse.store(fixture("small.png"),
                 preview: fn file, path ->
                   assert File.exists?(path)
                   "/previews/" <> file.key
                 end
               )

      assert {:ok, %{preview: nil}} =
               Storehouse.store(fixture("small.png"), preview: fn _, _ -> raise "no" end)

      assert {:ok, %{preview: nil}} =
               Storehouse.store(fixture("small.png"), preview: fn _, _ -> "javascript:1" end)
    end
  end

  describe "fetch/2" do
    setup do
      %{base: "http://127.0.0.1:#{StorehouseTest.FilesServer.start()}"}
    end

    test "downloads a file from a host the app allows, and stores it", %{base: base, root: root} do
      assert {:ok, file} =
               Storehouse.fetch(base <> "/harbour.jpg", hosts: ["127.0.0.1"], http: true)

      assert %{name: "harbour.jpg", content_type: "image/jpeg", width: 1200, height: 800} = file
      assert File.read!(Path.join(root, file.key)) == File.read!(fixture("harbour.jpg"))
    end

    test "follows a redirect to a host the app allows, and no other", %{base: base} do
      opts = [hosts: ["127.0.0.1"], http: true]
      assert {:ok, %{name: "small.png", width: 4}} = Storehouse.fetch(base <> "/moved", opts)
      assert {:error, :not_allowed} = Storehouse.fetch(base <> "/away", opts)
      assert {:error, :too_many_redirects} = Storehouse.fetch(base <> "/loop", opts)
    end

    test "refuses what the app does not allow, before it downloads anything", %{base: base} do
      assert {:error, :not_allowed} = Storehouse.fetch(base <> "/small.png", hosts: ["127.0.0.1"])

      assert {:error, :not_allowed} =
               Storehouse.fetch(base <> "/small.png", hosts: ["example.com"], http: true)

      assert {:error, :not_allowed} = Storehouse.fetch("file:///etc/passwd", hosts: ["127.0.0.1"])
    end

    test "checks the bytes, and stops a download too large", %{base: base} do
      opts = [hosts: ["127.0.0.1"], http: true]

      assert {:error, :not_accepted} =
               Storehouse.fetch(base <> "/page.png", [accept: Storehouse.Check.images()] ++ opts)

      assert {:error, :too_large} =
               Storehouse.fetch(base <> "/harbour.jpg", [max_bytes: 4_000] ++ opts)

      assert {:error, {:http, 404}} = Storehouse.fetch(base <> "/none.png", opts)

      assert Path.wildcard(Path.join(System.tmp_dir!(), "storehouse-*"))
             |> Enum.filter(&File.regular?/1) == []
    end

    test "no answer is read past :max_bytes, whatever its status, nor past :timeout", %{
      base: base
    } do
      opts = [hosts: ["127.0.0.1"], http: true, max_bytes: 100_000]

      # Each 5 MB, a chunk at a time: stopped near the limit, not read whole.
      for path <- ["/big-redirect", "/big-203", "/big-500"] do
        task = Task.async(fn -> Storehouse.fetch(base <> path, opts) end)
        assert Task.await(task) == {:error, :too_large}, path
      end

      assert {:error, :timeout} =
               Storehouse.fetch(base <> "/slow", hosts: ["127.0.0.1"], http: true, timeout: 500)
    end
  end
end
