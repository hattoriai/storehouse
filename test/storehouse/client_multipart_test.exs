defmodule Storehouse.ClientMultipartTest do
  # The JavaScript client, run by Node, sending a large file in parts
  # through the app's Storehouse.Plug.Multipart straight to a bucket at
  # S3_ENDPOINT (moto in CI), as a browser would.
  use ExUnit.Case, async: false

  @moduletag :node
  @moduletag :s3

  setup do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "storehouse-client-#{System.unique_integer([:positive])}"

    Application.put_env(:storehouse, Storehouse.S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: "test",
      secret_access_key: "test"
    )

    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(:put, {~c"#{endpoint}/#{bucket}", [], ~c"", ""}, [], [])

    server =
      start_supervised!({Bandit, plug: StorehouseTest.ClientApp, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.S3) end)
    %{base: "http://127.0.0.1:#{port}"}
  end

  test "a large file in parts, put together, checked and kept", %{base: base} do
    {output, status} = System.cmd("node", [Path.expand("../js/e2e_multipart.mjs", __DIR__), base])

    assert status == 0, output

    assert %{"status" => "registered", "value" => %{"file" => file}} =
             Storehouse.JSON.decode!(output)

    assert "accounts/42/" <> _ = file["key"]
    assert file["bytes"] == 12 * 1_048_576
    assert file["content_type"] == "application/zip"

    {:ok, stored} = Storehouse.read(file["key"], adapter: Storehouse.S3)

    # The node script's bytes: a ZIP's first four, then i rem 251 at i.
    n = 12 * 1_048_576
    cycle = :binary.copy(:binary.list_to_bin(Enum.to_list(0..250)), div(n, 251) + 1)
    expected = <<0x50, 0x4B, 0x03, 0x04>> <> binary_part(cycle, 4, n - 4)

    assert stored == expected
  end
end
