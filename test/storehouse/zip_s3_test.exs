defmodule Storehouse.ZipS3Test do
  # A zip of a bucket's files, streamed into the bucket in parts, at
  # S3_ENDPOINT (moto in CI).
  use ExUnit.Case, async: false

  @moduletag :s3

  alias Storehouse.{S3, Zip}

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-zip-#{System.unique_integer([:positive])}"

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

  @tag :tmp_dir
  test "two thousand files, zipped into the bucket in parts, each as it was", %{tmp_dir: dir} do
    entries =
      1..2_000
      |> Task.async_stream(
        fn i ->
          path = Path.join(dir, "#{i}.txt")
          File.write!(path, :binary.copy("#{i} ", 2_000))
          {:ok, _url} = S3.put("photos/#{i}.txt", path, %{content_type: "text/plain"})
          {"photos/#{i}.txt", {:stored, "photos/#{i}.txt"}}
        end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, entry} -> entry end)

    {:ok, size} = Zip.size(entries, adapter: S3)
    assert {:ok, file} = Zip.store(entries, "exports/all.zip", adapter: S3)
    assert file.bytes == size
    assert size > 16 * 1_048_576

    {:ok, zip} = Storehouse.read(file.key, adapter: S3)
    {:ok, files} = :zip.unzip(zip, [:memory])
    assert length(files) == 2_000
    assert {~c"photos/1999.txt", :binary.copy("1999 ", 2_000)} in files
  end
end
