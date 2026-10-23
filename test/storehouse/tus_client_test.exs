defmodule Storehouse.TusClientTest do
  # tuspy, a tus client of the protocol's own project, against the plug
  # behind a real server: to the local disk, and to a bucket at
  # S3_ENDPOINT (moto in CI) in parts. Where python3 has tusclient.
  use ExUnit.Case, async: false

  @moduletag :tuspy
  @moduletag :tmp_dir

  @script Path.expand("../python/tus_upload.py", __DIR__)

  setup %{tmp_dir: dir} do
    start_supervised!(Storehouse.Tus)
    Application.put_env(:storehouse, Storehouse.Local, root: dir)
    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.Local) end)
    :ok
  end

  defp serve(adapter) do
    # Bandit calls init/1 itself.
    plug = {Storehouse.Tus.Plug, owner: "accounts/42", part_bytes: 5_242_880, adapter: adapter}

    server = start_supervised!({Bandit, plug: plug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/"
  end

  defp upload(endpoint, path, chunk) do
    {output, status} =
      System.cmd(python(), [@script, endpoint, path, "export.zip", "application/zip", "#{chunk}"],
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end

  defp python, do: System.get_env("STOREHOUSE_PYTHON", "python3")

  defp zip(dir, bytes) do
    path = Path.join(dir, "export.zip")
    File.write!(path, <<"PK", 3, 4>> <> :crypto.strong_rand_bytes(bytes - 4))
    path
  end

  test "to the local disk, resumed from the server's offset", %{tmp_dir: dir} do
    path = zip(dir, 300_000)
    upload(serve(Storehouse.Local), path, 100_000)

    assert [key] =
             dir
             |> Path.join("accounts/42/**/*.zip")
             |> Path.wildcard()
             |> Enum.map(&Path.relative_to(&1, dir))

    assert File.read!(Path.join(dir, key)) == File.read!(path)
  end

  @tag :s3
  test "to a bucket, in parts, resumed from the server's offset", %{tmp_dir: dir} do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-tus-#{System.unique_integer([:positive])}"

    Application.put_env(:storehouse, Storehouse.S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: "test",
      secret_access_key: "test"
    )

    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.S3) end)
    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    path = zip(dir, 12 * 1_048_576)
    upload(serve(Storehouse.S3), path, 3 * 1_048_576)

    {:ok, entries} = Storehouse.list("accounts/42/", adapter: Storehouse.S3)
    assert [%{key: key, bytes: bytes}] = Enum.to_list(entries)
    assert bytes == 12 * 1_048_576
    assert Storehouse.read(key, adapter: Storehouse.S3) == {:ok, File.read!(path)}
  end
end
