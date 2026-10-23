defmodule Storehouse.ArchiveS3Test do
  # An archive of a bucket's files, streamed into the bucket in parts, at
  # S3_ENDPOINT (moto in CI).
  use ExUnit.Case, async: false

  @moduletag :s3

  alias Storehouse.{Archive, S3}

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-archive-#{System.unique_integer([:positive])}"

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
  test "two thousand files, archived into the bucket in parts, each as it was", %{tmp_dir: dir} do
    entries =
      1..2_000
      |> Task.async_stream(
        fn i ->
          path = Path.join(dir, "#{i}.jpg")
          File.write!(path, :crypto.strong_rand_bytes(10_000))
          {:ok, _url} = S3.put("photos/#{i}.jpg", path, %{content_type: "image/jpeg"})
          {"photos/#{i}.jpg", {:stored, "photos/#{i}.jpg"}}
        end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, entry} -> entry end)

    {:ok, size} = Archive.size(entries, adapter: S3)
    assert {:ok, file} = Archive.store(entries, "exports/all.zip", adapter: S3)
    assert file.bytes == size
    assert size > 16 * 1_048_576

    {:ok, zip} = Storehouse.read(file.key, adapter: S3)
    {:ok, files} = :zip.unzip(zip, [:memory])
    assert length(files) == 2_000
    assert {~c"photos/1999.jpg", File.read!(Path.join(dir, "1999.jpg"))} in files
  end
end
