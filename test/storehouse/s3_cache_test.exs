defmodule Storehouse.S3CacheTest do
  # The Cache-Control a bucket serves each file with, kept however the file
  # came in: stored, uploaded from the browser, streamed, promoted. At
  # S3_ENDPOINT (moto in CI).
  use ExUnit.Case, async: false

  @moduletag :s3

  alias Storehouse.S3

  @fixtures Path.expand("../fixtures", __DIR__)
  @year "public, max-age=31536000, immutable"

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-cache-#{System.unique_integer([:positive])}"

    Application.put_env(:storehouse, S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: "test",
      secret_access_key: "test",
      cache_control: @year
    )

    on_exit(fn -> Application.delete_env(:storehouse, S3) end)
    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    :ok
  end

  # What the bucket serves the file with, as a browser asks for it.
  defp served(key) do
    {:ok, url} = Storehouse.signed_url(key, adapter: S3)

    {:ok, {{_, 200, _}, headers, _body}} =
      :httpc.request(:head, {String.to_charlist(url), []}, [], [])

    headers |> List.keyfind(~c"cache-control", 0) |> then(&(&1 && to_string(elem(&1, 1))))
  end

  test "a file stored" do
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: S3)
    assert served(file.key) == @year

    {:ok, other} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"),
        adapter: S3,
        cache_control: "private, max-age=60"
      )

    assert served(other.key) == "private, max-age=60"
  end

  test "a file uploaded from the browser, its header signed" do
    data = File.read!(Path.join(@fixtures, "small.png"))

    {:ok, upload} =
      Storehouse.presign_upload("small.png", "image/png", byte_size(data), adapter: S3)

    assert upload.headers["cache-control"] == @year
    assert upload.url =~ "cache-control"

    headers =
      Enum.map(upload.headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:put, {String.to_charlist(upload.url), headers, ~c"image/png", data}, [], [])

    assert served(upload.key) == @year
  end

  test "a file streamed in" do
    {:ok, file} = Storehouse.Archive.store([{"a.txt", "words"}], "exports/a.zip", adapter: S3)
    assert served(file.key) == @year
  end

  test "a file promoted, and one copied from a store that keeps none" do
    {:ok, cached} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: S3, cache: true)

    {:ok, promoted} = Storehouse.promote(cached, adapter: S3)
    assert served(promoted.key) == @year

    # Stored without it, copied into a store that has it: written again.
    config = Application.get_env(:storehouse, S3)
    Application.put_env(:storehouse, S3, Keyword.delete(config, :cache_control))
    {:ok, bare} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: S3)
    assert served(bare.key) == nil

    Application.put_env(:storehouse, S3, config)
    assert :ok = S3.copy(bare.key, "copies/harbour.jpg")
    assert served("copies/harbour.jpg") == @year

    assert {:ok, %{content_type: "image/jpeg", checksum: checksum}} =
             Storehouse.head("copies/harbour.jpg", adapter: S3)

    assert checksum == bare.checksum
  end
end
