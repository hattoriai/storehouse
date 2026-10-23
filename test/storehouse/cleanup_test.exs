defmodule Storehouse.CleanupTest do
  # The root is application config.
  use ExUnit.Case, async: false

  alias Storehouse.Local

  # The local disk, whose deletions fail as many times as the test says,
  # each one sent to the test.
  defmodule Flaky do
    @behaviour Storehouse.Adapter

    @impl true
    defdelegate put(key, path, meta), to: Local
    @impl true
    defdelegate url(key), to: Local
    @impl true
    defdelegate list(prefix), to: Local

    @impl true
    def delete(key) do
      send(Application.fetch_env!(:storehouse, :test_pid), {:delete, key})
      failures = :persistent_term.get({__MODULE__, :failures})

      if :atomics.sub_get(failures, 1, 1) >= 0,
        do: {:error, :unavailable},
        else: Local.delete(key)
    end

    def fail(times) do
      failures = :atomics.new(1, signed: true)
      :atomics.put(failures, 1, times)
      :persistent_term.put({__MODULE__, :failures}, failures)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-clean-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Local, root: root)
    Application.put_env(:storehouse, :test_pid, self())
    Flaky.fail(0)

    on_exit(fn ->
      Application.delete_env(:storehouse, Local)
      Application.delete_env(:storehouse, :test_pid)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp write(root, key, body \\ "x") do
    path = Path.join(root, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    key
  end

  defp keys(prefix, opts \\ []) do
    {:ok, entries} = Storehouse.list(prefix, opts)
    Enum.map(entries, & &1.key)
  end

  describe "list/2" do
    test "gives the files under a prefix, in the order of their keys", %{root: root} do
      for key <-
            ~w(accounts/2/b.png accounts/1/z.png accounts/1/a.png accounts/10/c.png other.txt),
          do: write(root, key, "four")

      assert keys("accounts/1/") == ~w(accounts/1/a.png accounts/1/z.png)
      assert keys("accounts/1") == ~w(accounts/1/a.png accounts/1/z.png accounts/10/c.png)
      assert keys("accounts/") |> length() == 4
      assert keys("nothing/") == []

      {:ok, entries} = Storehouse.list("other.txt")
      [entry] = Enum.to_list(entries)
      assert entry.bytes == 4
      assert DateTime.diff(DateTime.utc_now(), entry.modified_at) < 60
    end

    test "leaves out the files of streams not closed yet", %{root: root} do
      write(root, "2026/10/a.png")
      write(root, "2026/10/b.png.part-123")

      assert keys("2026/") == ["2026/10/a.png"]
    end

    test "refuses a prefix that is empty or could leave the root" do
      for prefix <- ["", "/", "../", "a/../../b", "a//"],
          do: assert(Storehouse.list(prefix) == {:error, :invalid_prefix})
    end
  end

  describe "delete_prefix/2" do
    test "deletes every file under the prefix, and no other", %{root: root} do
      for n <- 1..5, do: write(root, "accounts/1/#{n}.png")
      write(root, "accounts/10/kept.png")

      assert Storehouse.delete_prefix("accounts/1/") == {:ok, 5}
      assert keys("accounts/") == ["accounts/10/kept.png"]
      assert Storehouse.delete_prefix("accounts/1/") == {:ok, 0}
    end

    test "deletes one at a time with a store that cannot delete many", %{root: root} do
      for n <- 1..3, do: write(root, "cache/#{n}.png")

      assert Storehouse.delete_prefix("cache/", adapter: Flaky) == {:ok, 3}
      for _n <- 1..3, do: assert_received({:delete, "cache/" <> _})
      assert keys("cache/") == []
    end

    test "never deletes everything" do
      assert Storehouse.delete_prefix("") == {:error, :invalid_prefix}
      assert Storehouse.delete_prefix("/") == {:error, :invalid_prefix}
    end

    test "stops at the store's first error", %{root: root} do
      write(root, "cache/1.png")
      Flaky.fail(1)

      assert Storehouse.delete_prefix("cache/", adapter: Flaky) == {:error, :unavailable}
    end
  end

  describe "delete_later/2" do
    test "deletes at once without a cleaner", %{root: root} do
      key = write(root, "2026/10/a.png")

      assert Storehouse.delete_later(key) == :ok
      refute File.exists?(Path.join(root, key))

      Flaky.fail(1)
      assert Storehouse.delete_later(key, adapter: Flaky) == {:error, :unavailable}
    end

    test "refuses a key or prefix that is not valid" do
      assert Storehouse.delete_later("../a.png") == {:error, :invalid_key}
      assert Storehouse.delete_prefix_later("/") == {:error, :invalid_prefix}
    end

    test "with a cleaner, retries until the store answers", %{root: root} do
      start_supervised!({Storehouse.Cleaner, backoff: fn _attempt -> 10 end})
      key = write(root, "2026/10/a.png")
      Flaky.fail(2)

      assert Storehouse.delete_later(key, adapter: Flaky) == :ok

      for _attempt <- 1..3, do: assert_receive({:delete, ^key}, 1_000)
      refute_receive {:delete, ^key}, 100
      refute File.exists?(Path.join(root, key))
    end

    test "with a cleaner, gives up after :max_attempts", %{root: root} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :cleaner, :discarded]])
      start_supervised!({Storehouse.Cleaner, max_attempts: 3, backoff: fn _attempt -> 10 end})
      key = write(root, "2026/10/a.png")
      Flaky.fail(100)

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Storehouse.delete_later(key, adapter: Flaky)

        assert_receive {[:storehouse, :cleaner, :discarded], ^ref, %{attempts: 3},
                        %{target: {:key, ^key}, reason: :unavailable}},
                       1_000
      end)

      assert File.exists?(Path.join(root, key))
    end

    test "with a cleaner, deletes a prefix", %{root: root} do
      start_supervised!(Storehouse.Cleaner)
      for n <- 1..3, do: write(root, "accounts/7/#{n}.png")

      assert Storehouse.delete_prefix_later("accounts/7/") == :ok
      wait_until(fn -> keys("accounts/") == [] end)
    end
  end

  describe "sweeping" do
    setup %{root: root} do
      old = write(root, Storehouse.cache_prefix() <> "2026/09/old.png")
      File.touch!(Path.join(root, old), System.os_time(:second) - 2 * 86_400)
      new = write(root, Storehouse.cache_prefix() <> "2026/10/new.png")
      kept = write(root, "2026/09/permanent.png")
      File.touch!(Path.join(root, kept), System.os_time(:second) - 2 * 86_400)

      %{old: old, new: new, kept: kept}
    end

    test "sweep/1 deletes the temporary files older than :max_age", ctx do
      assert Storehouse.Cleaner.sweep(max_age: 86_400) == {:ok, 1}

      refute File.exists?(Path.join(ctx.root, ctx.old))
      assert File.exists?(Path.join(ctx.root, ctx.new))
      assert File.exists?(Path.join(ctx.root, ctx.kept))
    end

    test "the cleaner sweeps on its own", ctx do
      start_supervised!({Storehouse.Cleaner, sweep: [max_age: 86_400, every: 3_600]})

      wait_until(fn -> not File.exists?(Path.join(ctx.root, ctx.old)) end)
      assert File.exists?(Path.join(ctx.root, ctx.new))
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(20) == :ok and wait_until(fun, tries - 1)
    end
  end
end
