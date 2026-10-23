defmodule Storehouse.ProxyServerTest do
  # The proxy behind a real server (Bandit), with a store on the disk: the
  # length it says is the length it sends, in parts.
  use ExUnit.Case, async: false

  alias StorehouseTest.Shared

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  @tag :tmp_dir
  test "a file streamed whole and in part, its length said", %{tmp_dir: dir} do
    Application.put_env(:storehouse, Shared, root: dir)
    on_exit(fn -> Application.delete_env(:storehouse, Shared) end)
    {:ok, file} = Storehouse.store(@harbour, adapter: Shared)

    plug =
      {Storehouse.Proxy,
       Storehouse.Proxy.init(authorize: true, adapter: Shared, chunk_bytes: 4_096)}

    {:ok, server} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = ~c"http://127.0.0.1:#{port}/#{file.key}"

    {:ok, {{_, 200, _}, headers, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert body == File.read!(@harbour)
    assert {~c"content-length", ~c"35367"} in headers
    refute List.keymember?(headers, ~c"transfer-encoding", 0)

    {:ok, {{_, 206, _}, _headers, part}} =
      :httpc.request(:get, {url, [{~c"range", ~c"bytes=5000-14999"}]}, [], body_format: :binary)

    assert part == binary_part(File.read!(@harbour), 5_000, 10_000)
  end
end
