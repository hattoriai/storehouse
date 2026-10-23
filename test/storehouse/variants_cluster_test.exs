defmodule Storehouse.VariantsClusterTest do
  # Two nodes asking for one variant at the same time, of a store on a
  # disk they share: it is made once.
  use ExUnit.Case, async: false

  @moduletag :cluster

  alias StorehouseTest.Renderers.Counting
  alias StorehouseTest.Shared

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  setup_all do
    {_, 0} = System.cmd("epmd", ["-daemon"])

    unless Node.alive?() do
      {:ok, _} = Node.start(:"storehouse_test@127.0.0.1", :longnames)
      on_exit(fn -> Node.stop() end)
    end

    {:ok, peer, other} =
      :peer.start(%{
        name: :"storehouse_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    {:ok, _apps} = :erpc.call(other, Application, :ensure_all_started, [:storehouse])
    :ok = :global.sync()

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _stopped -> :ok
      end
    end)

    %{other: other}
  end

  @tag :tmp_dir
  test "a variant two nodes ask for at once is made once", %{other: other, tmp_dir: dir} do
    for node <- [node(), other],
        do: :erpc.call(node, Application, :put_env, [:storehouse, Shared, [root: dir]])

    {:ok, file} = Storehouse.store(@harbour, adapter: Shared)

    opts = [
      presets: [thumb: [width: 320]],
      adapter: Shared,
      renderer: {Counting, test: self(), sleep: 300}
    ]

    ask = fn node ->
      fn -> :erpc.call(node, Storehouse, :variant, [file.key, :thumb, opts]) end
    end

    results =
      [node(), other]
      |> List.duplicate(25)
      |> List.flatten()
      |> Enum.map(&Task.async(ask.(&1)))
      |> Task.await_many(30_000)

    assert [{:ok, thumb}] = Enum.uniq_by(results, fn {:ok, variant} -> variant.key end)
    assert File.exists?(Path.join(dir, thumb.key))
    assert_received {:rendered, _node, :thumb, 320}
    refute_received {:rendered, _node, _preset, _width}
  end
end
