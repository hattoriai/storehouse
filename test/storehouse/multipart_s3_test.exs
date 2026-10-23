defmodule Storehouse.MultipartS3Test do
  # Very large files sent from the browser in parts, straight to a bucket
  # at S3_ENDPOINT (moto in CI): a browser's PUTs of signed URLs, as they
  # would be sent.
  use ExUnit.Case, async: false

  @moduletag :s3

  import Plug.Test

  alias Storehouse.Plug.Multipart, as: MultipartPlug
  alias Storehouse.S3

  @mib 1_048_576

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-multipart-#{System.unique_integer([:positive])}"

    Application.put_env(:storehouse, S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: "test",
      secret_access_key: "test"
    )

    on_exit(fn -> Application.delete_env(:storehouse, S3) end)
    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    :ok
  end

  # A file of `bytes`: a ZIP's first bytes, then noise.
  defp zip(bytes), do: <<"PK", 3, 4>> <> :crypto.strong_rand_bytes(bytes - 4)

  defp sha(part), do: Base.encode64(:crypto.hash(:sha256, part))

  defp chunks(data, size) do
    for {offset, n} <-
          Stream.iterate(0, &(&1 + size))
          |> Stream.take_while(&(&1 < byte_size(data)))
          |> Stream.with_index(1),
        do: {n, binary_part(data, offset, min(size, byte_size(data) - offset))}
  end

  # The browser's PUT of a signed part.
  defp put(%{url: url, headers: headers}, body) do
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

    {:ok, {{_, status, _}, _, _}} =
      :httpc.request(:put, {String.to_charlist(url), headers, ~c"", body}, [], [])

    status
  end

  defp send_parts(upload, parts) do
    numbered = for {n, part} <- parts, do: {n, sha(part)}
    {:ok, signed} = Storehouse.presign_parts(upload.key, upload.upload_id, numbered, adapter: S3)

    for {url, {_n, part}} <- Enum.zip(signed, parts), do: assert(put(url, part) == 200)
  end

  test "a file in parts, sent again from where it stopped after a reload, then checked" do
    data = zip(11 * @mib)

    assert {:ok, upload} =
             Storehouse.presign_multipart("export.zip", "application/zip", byte_size(data),
               adapter: S3,
               owner: "accounts/7",
               part_bytes: 5 * @mib
             )

    assert upload.part_bytes == 5 * @mib
    assert upload.parts == 3
    assert String.starts_with?(upload.key, "accounts/7/")

    [first, second, third] = chunks(data, upload.part_bytes)
    send_parts(upload, [first, second])

    # Reloaded: the store says what it has, and only the rest is sent.
    assert {:ok, [%{number: 1, bytes: 5_242_880}, %{number: 2}]} =
             Storehouse.multipart_parts(upload.key, upload.upload_id, adapter: S3)

    assert {:error, {:missing_parts, [3]}} =
             Storehouse.complete_multipart(upload.key, upload.upload_id, byte_size(data),
               adapter: S3
             )

    send_parts(upload, [third])

    assert {:error, {:wrong_size, total}} =
             Storehouse.complete_multipart(upload.key, upload.upload_id, byte_size(data) + 1,
               adapter: S3
             )

    assert total == byte_size(data)

    assert {:ok, file} =
             Storehouse.complete_multipart(upload.key, upload.upload_id, byte_size(data),
               adapter: S3,
               name: "export.zip"
             )

    assert file.bytes == byte_size(data)
    assert file.content_type == "application/zip"
    assert Storehouse.read(file.key, adapter: S3) == {:ok, data}
  end

  # The bucket refuses a part whose bytes are not its checksum's: S3 does;
  # moto takes it, so here the URL is checked to sign the checksum, which
  # the browser must then send.
  test "each part signed with its checksum" do
    {:ok, upload} =
      Storehouse.presign_multipart("a.zip", "application/zip", 6 * @mib, adapter: S3)

    sum = sha("part")

    {:ok, [signed]} =
      Storehouse.presign_parts(upload.key, upload.upload_id, [{1, sum}], adapter: S3)

    assert signed.headers == %{"x-amz-checksum-sha256" => sum}
    assert signed.url =~ "X-Amz-SignedHeaders=host%3Bx-amz-checksum-sha256"
    assert signed.url =~ "partNumber=1"
  end

  test "the file checked once it is whole: a page sent as an archive is deleted" do
    page = "<html><script>alert(1)</script>" <> String.duplicate(" ", 6 * @mib)

    {:ok, upload} =
      Storehouse.presign_multipart("a.zip", "application/zip", byte_size(page), adapter: S3)

    send_parts(upload, chunks(page, upload.part_bytes))

    assert {:error, :not_accepted} =
             Storehouse.complete_multipart(upload.key, upload.upload_id, byte_size(page),
               adapter: S3,
               accept: ["application/zip"]
             )

    assert {:error, :enoent} = Storehouse.head(upload.key, adapter: S3)
  end

  test "refused before a byte is sent, as a single upload is" do
    assert {:error, :not_accepted} =
             Storehouse.presign_multipart("a.exe", "application/x-msdownload", 10,
               adapter: S3,
               accept: ["application/zip"]
             )

    assert {:error, :too_large} =
             Storehouse.presign_multipart("a.zip", "application/zip", 100,
               adapter: S3,
               max_bytes: 99
             )

    assert {:error, :storage_full} =
             Storehouse.presign_multipart("a.zip", "application/zip", 100, adapter: S3, room: 99)

    # 300 GB: parts of 16 MiB would be more than 10,000.
    assert {:ok, big} =
             Storehouse.presign_multipart("a.zip", "application/zip", 300_000_000_000,
               adapter: S3
             )

    assert big.parts <= 10_000
    assert big.part_bytes > 16 * @mib

    assert {:error, :invalid_part} =
             Storehouse.presign_parts(big.key, big.upload_id, [0], adapter: S3)

    assert {:error, :invalid_part} =
             Storehouse.presign_parts(big.key, big.upload_id, [{1, "short"}], adapter: S3)
  end

  test "an upload given up, and those abandoned swept" do
    {:ok, given_up} =
      Storehouse.presign_multipart("a.zip", "application/zip", 6 * @mib, adapter: S3)

    assert :ok = Storehouse.abort_multipart(given_up.key, given_up.upload_id, adapter: S3)

    assert {:error, _gone} =
             Storehouse.multipart_parts(given_up.key, given_up.upload_id, adapter: S3)

    {:ok, _abandoned} =
      Storehouse.presign_multipart("b.zip", "application/zip", 6 * @mib, adapter: S3)

    # moto says every upload was started in 2010: it is swept at once.
    assert {:ok, [_one]} = S3.multipart_uploads("")
    assert {:ok, 1} = Storehouse.Sweeper.sweep(adapter: S3)
    assert {:ok, []} = S3.multipart_uploads("")
  end

  describe "Storehouse.Plug.Multipart" do
    defp call(action, body, opts \\ []) do
      opts =
        MultipartPlug.init(Keyword.merge([adapter: S3, owner: "accounts/7"], opts))

      conn =
        conn(:post, "/#{action}", Storehouse.JSON.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> MultipartPlug.call(opts)

      {conn.status, Storehouse.JSON.decode!(conn.resp_body)}
    end

    test "started, signed, listed, completed, as the browser asks" do
      data = zip(7 * @mib)

      assert {200, %{"upload" => upload}} =
               call("start", %{
                 "name" => "a.zip",
                 "type" => "application/zip",
                 "bytes" => byte_size(data)
               })

      %{"key" => key, "upload_id" => id, "part_bytes" => size} = upload
      [{1, first}] = chunks(data, size)

      assert {200, %{"parts" => [signed]}} =
               call("sign", %{
                 "key" => key,
                 "upload_id" => id,
                 "parts" => [%{"number" => 1, "checksum" => sha(first)}]
               })

      assert put(%{url: signed["url"], headers: signed["headers"]}, first) == 200

      assert {200, %{"parts" => [%{"number" => 1, "bytes" => bytes}]}} =
               call("list", %{"key" => key, "upload_id" => id})

      assert bytes == byte_size(data)

      assert {200, %{"file" => %{"key" => ^key, "bytes" => ^bytes}}} =
               call("complete", %{
                 "key" => key,
                 "upload_id" => id,
                 "bytes" => bytes,
                 "name" => "a.zip"
               })
    end

    test "another owner's upload is not signed, listed, completed or given up" do
      {200, %{"upload" => %{"key" => key, "upload_id" => id}}} =
        call("start", %{"name" => "a.zip", "type" => "application/zip", "bytes" => 6 * @mib})

      for {action, body} <- [
            {"sign", %{"parts" => [%{"number" => 1}]}},
            {"list", %{}},
            {"complete", %{"bytes" => 1}},
            {"abort", %{}}
          ] do
        body = Map.merge(body, %{"key" => key, "upload_id" => id})
        assert {403, %{"error" => "not_owner"}} = call(action, body, owner: "accounts/8")
      end

      assert {200, %{"ok" => true}} = call("abort", %{"key" => key, "upload_id" => id})
    end

    test "what is not the JSON it takes, and a file refused" do
      assert {400, %{"error" => "invalid_request"}} = call("start", %{"name" => "a.zip"})

      assert {400, %{"error" => "invalid_request"}} =
               call("sign", %{"key" => "../x", "upload_id" => "1", "parts" => []})

      assert {422, %{"error" => "too_large"}} =
               call("start", %{"name" => "a.zip", "type" => "application/zip", "bytes" => 100},
                 max_bytes: 10
               )
    end
  end

  @tag :large
  @tag timeout: 600_000
  test "300 MB in parts, halfway, then the rest after a reload" do
    data = zip(300 * @mib)

    {:ok, upload} =
      Storehouse.presign_multipart("film.zip", "application/zip", byte_size(data), adapter: S3)

    parts = chunks(data, upload.part_bytes)
    {sent, rest} = Enum.split(parts, div(length(parts), 2))

    send_parts(upload, sent)
    {:ok, have} = Storehouse.multipart_parts(upload.key, upload.upload_id, adapter: S3)
    have = MapSet.new(have, & &1.number)
    send_parts(upload, Enum.reject(rest, fn {n, _part} -> n in have end))

    assert {:ok, file} =
             Storehouse.complete_multipart(upload.key, upload.upload_id, byte_size(data),
               adapter: S3
             )

    assert file.bytes == byte_size(data)
    assert Storehouse.read(file.key, adapter: S3) == {:ok, data}
  end
end
