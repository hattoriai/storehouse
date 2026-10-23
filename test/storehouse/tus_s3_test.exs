defmodule Storehouse.TusS3Test do
  # The tus plug to a bucket at S3_ENDPOINT (moto in CI): the bytes into a
  # multipart upload a part at a time, the rest of each PATCH kept for
  # the next.
  use ExUnit.Case, async: false

  @moduletag :s3

  import Plug.Test
  import Plug.Conn

  alias Storehouse.S3
  alias Storehouse.Tus.Plug, as: TusPlug
  alias Storehouse.Tus.State.ETS

  @mib 1_048_576

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-tus-#{System.unique_integer([:positive])}"

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

    start_supervised!(Storehouse.Tus)
    %{opts: TusPlug.init(adapter: S3, owner: "accounts/7", part_bytes: 5 * @mib)}
  end

  defp request(method, path, opts, headers, body \\ "") do
    conn(method, path, body)
    |> put_req_header("tus-resumable", "1.0.0")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, conn -> put_req_header(conn, k, v) end))
    |> TusPlug.call(opts)
  end

  defp zip(bytes), do: <<"PK", 3, 4>> <> :crypto.strong_rand_bytes(bytes - 4)

  test "12 MiB in PATCHes of 3: parts sent as they fill, the file whole in the bucket", %{
    opts: opts
  } do
    data = zip(12 * @mib)
    name = "filename #{Base.encode64("export.zip")},filetype #{Base.encode64("application/zip")}"

    conn =
      request(:post, "/", opts, [
        {"upload-length", "#{byte_size(data)}"},
        {"upload-metadata", name}
      ])

    assert conn.status == 201
    "http://www.example.com/" <> id = conn |> get_resp_header("location") |> hd()

    for offset <- [0, 3, 6, 9] do
      piece = binary_part(data, offset * @mib, 3 * @mib)

      headers = [
        {"content-type", "application/offset+octet-stream"},
        {"upload-offset", "#{offset * @mib}"}
      ]

      conn = request(:patch, "/#{id}", opts, headers, piece)
      assert conn.status == 204, "#{offset}: #{conn.status}"

      # The parts the store has so far: 5 MiB each, as they fill.
      if offset == 6 do
        upload = ETS.get(id)

        assert {:ok, [%{bytes: 5_242_880}]} =
                 Storehouse.multipart_parts(upload.key, upload.upload_id, adapter: S3)

        assert byte_size(upload.tail) == 4 * @mib
      end
    end

    {:ok, entries} = S3.list("accounts/7/")
    assert [%{key: key, bytes: bytes}] = Enum.to_list(entries)
    assert bytes == byte_size(data)
    assert Storehouse.read(key, adapter: S3) == {:ok, data}
  end

  test "given up: the multipart upload with it", %{opts: opts} do
    conn = request(:post, "/", opts, [{"upload-length", "#{12 * @mib}"}])
    "http://www.example.com/" <> id = conn |> get_resp_header("location") |> hd()
    assert {:ok, [_open]} = S3.multipart_uploads("")

    assert request(:delete, "/#{id}", opts, []).status == 204
    assert {:ok, []} = S3.multipart_uploads("")
  end
end
