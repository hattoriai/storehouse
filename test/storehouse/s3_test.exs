defmodule Storehouse.S3Test do
  # Storehouse.S3 against a store that speaks S3's API, at S3_ENDPOINT:
  # moto in CI, and LocalStack or MinIO as well (see test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :s3

  alias Storehouse.S3

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    bucket = "storehouse-#{System.unique_integer([:positive])}"
    endpoint = System.fetch_env!("S3_ENDPOINT")

    Application.put_env(:storehouse, S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: System.get_env("S3_ACCESS_KEY_ID", "test"),
      secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY", "test")
    )

    {:ok, 200, _body} = http(:put, "#{endpoint}/#{bucket}")
    on_exit(fn -> Application.delete_env(:storehouse, S3) end)
    %{bucket: bucket, endpoint: endpoint}
  end

  # A bucket made, or a signed URL read, as a browser does: no keys.
  defp http(method, url) do
    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(method, {String.to_charlist(url), []}, [], body_format: :binary)

    if method == :get,
      do: {:ok, status, body, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)},
      else: {:ok, status, body}
  end

  # The browser's part of an upload straight to the bucket.
  defp put_upload(upload, body) do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    type = String.to_charlist(upload.headers["content-type"])

    headers =
      for {k, v} <- upload.headers,
          k != "content-type",
          do: {String.to_charlist(k), String.to_charlist(v)}

    {:ok, {{_version, status, _reason}, _headers, _body}} =
      :httpc.request(:put, {String.to_charlist(upload.url), headers, type, body}, [], [])

    status
  end

  test "stores a file, serves it at a signed URL, and deletes it" do
    assert {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: S3)
    assert file.url =~ ~r"/storehouse-\d+/\d{4}/\d{2}/[0-9a-f-]+-harbour\.jpg\z"

    {:ok, url} = Storehouse.signed_url(file.key, adapter: S3, filename: "The quay.jpg")
    assert {:ok, 200, body, headers} = http(:get, url)
    assert body == File.read!(Path.join(@fixtures, "harbour.jpg"))
    assert headers["content-type"] == "image/jpeg"
    assert headers["content-disposition"] == ~s(attachment; filename="The quay.jpg")

    # Sent with its checksum, which the bucket checks and keeps.
    assert file.checksum == Storehouse.checksum(Path.join(@fixtures, "harbour.jpg"))
    assert {:ok, checksum} = S3.checksum(file.key)
    assert checksum == file.checksum

    assert {:ok, head, 35_367} = S3.read_head(file.key, 4)
    assert head == <<0xFF, 0xD8, 0xFF, 0xE0>>

    assert :ok = Storehouse.delete(file.key, adapter: S3)
    assert {:error, :enoent} = S3.read_head(file.key, 4)
    assert :ok = Storehouse.delete(file.key, adapter: S3)
  end

  test "stores a page as a download, never as a page" do
    assert {:ok, file} = Storehouse.store(Path.join(@fixtures, "not-an-image.png"), adapter: S3)
    assert file.content_type == "application/octet-stream"
    assert String.ends_with?(file.key, ".bin")

    {:ok, url} = Storehouse.signed_url(file.key, adapter: S3)
    assert {:ok, 200, _body, headers} = http(:get, url)
    assert headers["content-type"] == "application/octet-stream"
    assert headers["content-disposition"] == "attachment"
  end

  test "takes an upload straight to the bucket, and checks it there" do
    data = File.read!(Path.join(@fixtures, "small.png"))

    assert {:ok, upload} =
             Storehouse.presign_upload("Small.png", "image/png", byte_size(data), adapter: S3)

    assert upload.headers == %{"content-type" => "image/png", "content-disposition" => "inline"}

    assert upload.url =~
             "X-Amz-SignedHeaders=content-disposition%3Bcontent-length%3Bcontent-type%3Bhost"

    assert put_upload(upload, data) == 200

    # The browser sent no checksum: the bucket keeps none.
    assert {:ok, %Storehouse.File{name: "Small.png", width: 4, height: 3, checksum: nil}} =
             Storehouse.verify_upload(upload.key, adapter: S3, name: "Small.png")
  end

  test "deletes an upload whose bytes are not what it said" do
    page = "<html><script>alert(1)</script></html>"
    {:ok, upload} = Storehouse.presign_upload("a.png", "image/png", byte_size(page), adapter: S3)
    assert put_upload(upload, page) == 200

    assert {:error, :not_accepted} = Storehouse.verify_upload(upload.key, adapter: S3)
    assert {:error, :enoent} = S3.read_head(upload.key, 4)
  end

  test "reads the head of an empty file, and of a missing one" do
    empty = Path.join(System.tmp_dir!(), "storehouse-empty-#{System.unique_integer([:positive])}")
    File.write!(empty, "")
    {:ok, url} = S3.put("2026/10/empty.txt", empty, %{content_type: "text/plain"})
    File.rm!(empty)
    assert is_binary(url)
    assert {:ok, "", 0} = S3.read_head("2026/10/empty.txt", 10)
    assert {:error, :enoent} = S3.read_head("2026/10/none.txt", 10)
    assert {:error, :invalid_key} = S3.read_head("../x", 10)
  end

  test "reads a file back: its head, all of it, a stream of it, and a download" do
    harbour = File.read!(Path.join(@fixtures, "harbour.jpg"))
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: S3)

    assert {:ok, head} = Storehouse.head(file, adapter: S3)
    assert head == %{bytes: 35_367, content_type: "image/jpeg", checksum: file.checksum}

    assert Storehouse.read(file, adapter: S3) == {:ok, harbour}
    assert Storehouse.read(file, adapter: S3, max_bytes: 100) == {:error, {:too_large, 35_367}}

    assert {:ok, stream} = Storehouse.stream(file, adapter: S3, chunk_bytes: 10_000)
    chunks = Enum.to_list(stream)
    assert Enum.map(chunks, &byte_size/1) == [10_000, 10_000, 10_000, 5_367]
    assert IO.iodata_to_binary(chunks) == harbour

    path = Path.join(System.tmp_dir!(), "storehouse-s3-download-#{System.unique_integer()}")
    on_exit(fn -> File.rm(path) end)
    assert Storehouse.download(file, path, adapter: S3, chunk_bytes: 8_192) == :ok
    assert File.read!(path) == harbour

    assert S3.read_range(file.key, 35_000, 99_999) == {:ok, binary_part(harbour, 35_000, 367)}
    assert S3.read_range(file.key, 40_000, 40_100) == {:ok, ""}

    :ok = Storehouse.delete(file.key, adapter: S3)
    assert Storehouse.head(file, adapter: S3) == {:error, :enoent}
    assert Storehouse.read(file, adapter: S3) == {:error, :enoent}
    assert S3.read_range(file.key, 0, 10) == {:error, :enoent}
  end
end
