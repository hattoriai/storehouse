defmodule Storehouse.StoresTest do
  # Several stores side by side, each with its config (application config).
  use ExUnit.Case, async: false

  import Plug.Test

  alias Storehouse.Local.Plug, as: FilePlug
  alias StorehouseTest.{Media, PrivateFiles, Scratch}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)
  @secret String.duplicate("storehouse-stores-", 2)

  setup do
    base = Path.join(System.tmp_dir!(), "storehouse-stores-#{System.unique_integer([:positive])}")
    roots = for name <- ~w(default private scratch), into: %{}, do: {name, Path.join(base, name)}

    Application.put_env(:storehouse, Storehouse.Local, root: roots["default"], secret: @secret)

    Application.put_env(:storehouse, PrivateFiles,
      root: roots["private"],
      url_prefix: "/private",
      secret: @secret <> "-private"
    )

    Application.put_env(:storehouse_test, Scratch, root: roots["scratch"], url_prefix: "/scratch")

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      Application.delete_env(:storehouse, PrivateFiles)
      Application.delete_env(:storehouse_test, Scratch)
      File.rm_rf!(base)
    end)

    %{roots: roots}
  end

  test "each local store keeps its files under its own root, at its own prefix", %{roots: roots} do
    {:ok, default} = Storehouse.store(@harbour)
    {:ok, private} = Storehouse.store(@harbour, adapter: PrivateFiles)
    {:ok, scratch} = Storehouse.store(@harbour, adapter: Scratch)

    assert File.exists?(Path.join(roots["default"], default.key))
    assert File.exists?(Path.join(roots["private"], private.key))
    assert File.exists?(Path.join(roots["scratch"], scratch.key))
    refute File.exists?(Path.join(roots["default"], private.key))

    assert "/uploads/" <> _ = default.url
    assert "/private/" <> _ = private.url
    assert "/scratch/" <> _ = scratch.url

    assert Storehouse.read(private, adapter: PrivateFiles) == {:ok, File.read!(@harbour)}
    assert Storehouse.read(private) == {:error, :enoent}

    {:ok, cached} = Storehouse.store(@harbour, adapter: PrivateFiles, cache: true)
    {:ok, promoted} = Storehouse.promote(cached, adapter: PrivateFiles)
    assert File.exists?(Path.join(roots["private"], promoted.key))

    {:ok, entries} = Storehouse.list("2026/", adapter: PrivateFiles)
    assert private.key in Enum.map(entries, & &1.key)
    {:ok, entries} = Storehouse.list("", adapter: PrivateFiles, after: private.key)
    refute private.key in Enum.map(entries, & &1.key)

    :ok = Storehouse.delete(private.key, adapter: PrivateFiles)
    refute File.exists?(Path.join(roots["private"], private.key))
    assert File.exists?(Path.join(roots["default"], default.key))
  end

  test "a store's signatures are its own, and its plug serves only its files", %{roots: _roots} do
    {:ok, private} = Storehouse.store(@harbour, adapter: PrivateFiles)
    {:ok, url} = Storehouse.signed_url(private, adapter: PrivateFiles)

    plug = FilePlug.init(store: PrivateFiles, private: true)
    assert (conn(:get, url) |> FilePlug.call(plug)).status == 200

    # Signed by the default store's secret: not this store's.
    forged = String.replace(url, "/private/", "/uploads/")
    {:ok, default_signed} = Storehouse.signed_url(private.key)

    assert (conn(:get, String.replace(default_signed, "/uploads/", "/private/"))
            |> FilePlug.call(plug)).status == 403

    # This store's signature, at the default store's prefix: the default
    # store's plug refuses it, as not its own.
    default_plug = FilePlug.init(private: true)
    assert (conn(:get, forged) |> FilePlug.call(default_plug)).status == 403
  end

  test "an upload straight to a store, signed and checked by that store" do
    body = File.read!(@harbour)

    {:ok, upload} =
      Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body), adapter: PrivateFiles)

    assert "/private/" <> _ = upload.url

    plug = FilePlug.init(store: PrivateFiles)

    conn =
      conn(:put, upload.url, body)
      |> Plug.Conn.put_req_header("content-type", "image/jpeg")
      |> FilePlug.call(plug)

    assert conn.status == 200
    assert {:ok, file} = Storehouse.verify_upload(upload.key, adapter: PrivateFiles)
    assert file.width == 1200
    assert Storehouse.verify_upload(upload.key) == {:error, :enoent}
  end

  # The config a function gives, each time: a vault's keys.
  def private_config(root), do: [root: root, url_prefix: "/private", secret: @secret <> "-vault"]

  test "a store's config may be a function that gives it each time", %{roots: roots} do
    Application.put_env(
      :storehouse,
      PrivateFiles,
      {__MODULE__, :private_config, [roots["private"]]}
    )

    {:ok, file} = Storehouse.store(@harbour, adapter: PrivateFiles)
    assert File.exists?(Path.join(roots["private"], file.key))
    assert file.url == "/private/" <> file.key
    assert PrivateFiles.config()[:secret] == @secret <> "-vault"

    Application.put_env(
      :storehouse,
      Storehouse.Local,
      {__MODULE__, :private_config, [roots["default"]]}
    )

    assert Storehouse.Local.config()[:root] == roots["default"]

    Application.put_env(:storehouse, PrivateFiles, {__MODULE__, :nothing, []})
    assert_raise UndefinedFunctionError, fn -> PrivateFiles.config() end
    Application.put_env(:storehouse, PrivateFiles, {Map, :new, []})
    assert_raise ArgumentError, ~r/not a keyword list/, fn -> PrivateFiles.config() end
  end

  test "a stream to a store ends in that store", %{roots: roots} do
    {:ok, stream} =
      PrivateFiles.stream_open("2026/10/streamed.txt", %{content_type: "text/plain"})

    {:ok, stream} = PrivateFiles.stream_write(stream, "streamed")
    assert {:ok, "/private/2026/10/streamed.txt"} = PrivateFiles.stream_close(stream)
    assert File.read!(Path.join(roots["private"], "2026/10/streamed.txt")) == "streamed"
  end

  @tag :s3
  test "two buckets side by side" do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    [one, two] = for _n <- 1..2, do: "storehouse-#{System.unique_integer([:positive])}"

    config = fn bucket ->
      [
        bucket: bucket,
        region: "us-east-1",
        endpoint: endpoint,
        access_key_id: "test",
        secret_access_key: "test"
      ]
    end

    Application.put_env(:storehouse, Storehouse.S3, config.(one))
    Application.put_env(:storehouse, Media, config.(two))

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.S3)
      Application.delete_env(:storehouse, Media)
    end)

    {:ok, _apps} = Application.ensure_all_started(:inets)

    for bucket <- [one, two],
        do:
          {:ok, {{_, 200, _}, _, _}} =
            :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    {:ok, in_one} = Storehouse.store(@harbour, adapter: Storehouse.S3)
    {:ok, in_two} = Storehouse.store(@harbour, adapter: Media)

    assert in_one.url =~ "/#{one}/"
    assert in_two.url =~ "/#{two}/"
    assert {:ok, _bytes} = Storehouse.read(in_two, adapter: Media)
    assert Storehouse.head(in_two.key, adapter: Storehouse.S3) == {:error, :enoent}

    # Streamed in parts, to the second bucket.
    {:ok, stream} =
      Media.stream_open("2026/10/s.bin", %{
        content_type: "application/octet-stream"
      })

    {:ok, stream} = Media.stream_write(stream, :binary.copy("x", 1_000))
    {:ok, url} = Media.stream_close(stream)
    assert url =~ "/#{two}/"

    {:ok, signed} = Storehouse.signed_url(in_two, adapter: Media)
    assert signed =~ "/#{two}/"

    :ok = Storehouse.delete(in_two.key, adapter: Media)
    assert Storehouse.head(in_two.key, adapter: Media) == {:error, :enoent}
    assert {:ok, _head} = Storehouse.head(in_one.key, adapter: Storehouse.S3)
  end
end
