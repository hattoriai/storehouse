defmodule Storehouse.CopyS3Test do
  # Copies between two buckets, and between a bucket and the disk, at
  # S3_ENDPOINT (moto in CI).
  use ExUnit.Case, async: false

  @moduletag :s3

  alias StorehouseTest.{Media, PrivateFiles}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    [one, two] = for _ <- 1..2, do: "storehouse-copy-#{System.unique_integer([:positive])}"

    root =
      Path.join(System.tmp_dir!(), "storehouse-copy-s3-#{System.unique_integer([:positive])}")

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
    Application.put_env(:storehouse, PrivateFiles, root: root, url_prefix: "/private")

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.S3)
      Application.delete_env(:storehouse, Media)
      Application.delete_env(:storehouse, PrivateFiles)
      File.rm_rf!(root)
    end)

    {:ok, _apps} = Application.ensure_all_started(:inets)

    for bucket <- [one, two],
        do:
          {:ok, {{_, 200, _}, _, _}} =
            :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    :ok
  end

  @tag :tmp_dir
  test "a thousand files between two buckets, in S3, their types and checksums kept; then none",
       %{tmp_dir: dir} do
    body = File.read!(@harbour)
    path = Path.join(dir, "body")
    File.write!(path, body)
    checksum = Storehouse.checksum(path)

    1..1_000
    |> Task.async_stream(
      fn i ->
        {:ok, _url} =
          Storehouse.S3.put("photos/#{i}.jpg", path, %{
            content_type: "image/jpeg",
            checksum: checksum
          })
      end,
      max_concurrency: 16
    )
    |> Stream.run()

    assert Storehouse.copy_prefix("photos/", from: Storehouse.S3, to: Media, max_concurrency: 16) ==
             {:ok, %{copied: 1_000, skipped: 0, failed: []}}

    assert {:ok, %{content_type: "image/jpeg", bytes: bytes, checksum: ^checksum}} =
             Storehouse.head("photos/1000.jpg", adapter: Media)

    assert bytes == byte_size(body)
    assert Storehouse.read("photos/7.jpg", adapter: Media) == {:ok, body}

    assert Storehouse.copy_prefix("photos/", from: Storehouse.S3, to: Media, max_concurrency: 16) ==
             {:ok, %{copied: 0, skipped: 1_000, failed: []}}
  end

  test "from a bucket to the disk and back, a chunk at a time, its checksum checked" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Storehouse.S3)

    assert Storehouse.copy(file.key, from: Storehouse.S3, to: PrivateFiles) == {:ok, :copied}
    assert Storehouse.read(file.key, adapter: PrivateFiles) == {:ok, File.read!(@harbour)}

    assert Storehouse.copy(file.key, from: Storehouse.S3, to: PrivateFiles, verify: true) ==
             {:ok, :skipped}

    {:ok, local} = Storehouse.store(@harbour, adapter: PrivateFiles)
    assert Storehouse.copy(local.key, from: PrivateFiles, to: Media) == {:ok, :copied}

    assert {:ok, %{content_type: "image/jpeg", checksum: checksum}} =
             Storehouse.head(local.key, adapter: Media)

    assert checksum == Storehouse.checksum(@harbour)
    assert Storehouse.copy(local.key, from: PrivateFiles, to: Media) == {:ok, :skipped}
  end
end
