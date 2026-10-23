defmodule Storehouse.ClientTest do
  # The JavaScript client (priv/static/storehouse-client.mjs), run by Node
  # against the app's own endpoints and local store, as a browser would.
  use ExUnit.Case, async: false

  @moduletag :node
  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-client-#{System.unique_integer([:positive])}")

    Application.put_env(:storehouse, Storehouse.Local,
      root: root,
      secret: String.duplicate("storehouse-client-", 2)
    )

    server =
      start_supervised!({Bandit, plug: StorehouseTest.ClientApp, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{base: "http://127.0.0.1:#{port}", root: root}
  end

  test "presigns, sends, registers, and says what was refused", %{base: base, root: root} do
    {output, status} =
      System.cmd("node", [Path.expand("../js/e2e.mjs", __DIR__), base, @fixtures])

    assert status == 0, output
    assert [harbour, again, page, big] = Storehouse.JSON.decode!(output)

    # The same bytes twice: whichever is registered first is the file,
    # and the other is it.
    assert [%{"status" => "existing", "value" => existing}, %{"value" => %{"file" => file}}] =
             Enum.sort_by([harbour, again], & &1["status"])

    assert "accounts/42/" <> _ = file["key"]
    assert file["width"] == 1200
    assert existing["key"] == file["key"]
    assert File.exists?(Path.join(root, file["key"]))

    assert Path.wildcard(Path.join(root, "accounts/42/**/*.jpg")) == [
             Path.join(root, file["key"])
           ]

    assert page == %{"status" => "error", "error" => "not_accepted"}
    assert big == %{"status" => "error", "error" => "storage_full"}
  end
end
