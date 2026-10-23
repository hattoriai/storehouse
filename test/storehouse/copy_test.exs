defmodule Storehouse.CopyTest do
  # Two stores, each with its config (application config).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mix.Tasks.Storehouse.Copy, as: CopyTask
  alias Storehouse.Memory
  alias StorehouseTest.{Flaky, Mirrored, PrivateFiles, Scratch}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)
  @png Path.expand("../fixtures/small.png", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "storehouse-copy-#{System.unique_integer([:positive])}")
    roots = for name <- ~w(private scratch flaky), into: %{}, do: {name, Path.join(base, name)}

    Application.put_env(:storehouse, PrivateFiles, root: roots["private"], url_prefix: "/private")
    Application.put_env(:storehouse_test, Scratch, root: roots["scratch"], url_prefix: "/scratch")
    Application.put_env(:storehouse_test, Flaky, root: roots["flaky"], url_prefix: "/flaky")
    Memory.checkout()

    on_exit(fn ->
      Application.delete_env(:storehouse, PrivateFiles)
      Application.delete_env(:storehouse_test, Scratch)
      Application.delete_env(:storehouse_test, Flaky)
      Flaky.up()
      File.rm_rf!(base)
    end)

    %{roots: roots}
  end

  describe "copy/2" do
    test "between two folders of this disk, then skipped" do
      {:ok, file} = Storehouse.store(@harbour, adapter: PrivateFiles)

      assert Storehouse.copy(file.key, from: PrivateFiles, to: Scratch) == {:ok, :copied}
      assert Storehouse.read(file.key, adapter: Scratch) == {:ok, File.read!(@harbour)}
      assert Storehouse.copy(file.key, from: PrivateFiles, to: Scratch) == {:ok, :skipped}
    end

    test "a chunk at a time, between stores of different kinds, its type kept" do
      {:ok, file} = Storehouse.store(@png, adapter: Memory)

      assert Storehouse.copy(file.key, from: Memory, to: PrivateFiles) == {:ok, :copied}
      assert Storehouse.read(file.key, adapter: PrivateFiles) == {:ok, File.read!(@png)}

      {:ok, other} = Storehouse.store(@harbour, adapter: Scratch)
      assert Storehouse.copy(other.key, from: Scratch, to: Memory) == {:ok, :copied}

      assert {:ok, %{content_type: "image/jpeg", checksum: checksum}} =
               Storehouse.head(other.key, adapter: Memory)

      assert checksum == Storehouse.checksum(@harbour)
    end

    test "a file there already but different is copied over; of the same size, only with :verify" do
      {:ok, file} = Storehouse.store(@png, adapter: Memory)
      body = File.read!(@png)
      copy = Storehouse.Local.path(PrivateFiles.config(), file.key) |> elem(1)

      File.mkdir_p!(Path.dirname(copy))
      File.write!(copy, "shorter")
      assert Storehouse.copy(file.key, from: Memory, to: PrivateFiles) == {:ok, :copied}
      assert File.read!(copy) == body

      # The same size: the local disk keeps no checksum to compare.
      File.write!(copy, :binary.copy("x", byte_size(body)))
      assert Storehouse.copy(file.key, from: Memory, to: PrivateFiles) == {:ok, :skipped}

      assert Storehouse.copy(file.key, from: Memory, to: PrivateFiles, verify: true) ==
               {:ok, :copied}

      assert File.read!(copy) == body

      assert Storehouse.copy(file.key, from: Memory, to: PrivateFiles, verify: true) ==
               {:ok, :skipped}
    end

    defmodule Lying do
      @moduledoc false
      # A store whose checksum is not of the bytes it gives.
      @behaviour Storehouse.Adapter
      def put(_key, _path, _meta), do: {:error, :read_only}
      def url(key), do: "/lying/" <> key
      def delete(_key), do: :ok

      def head(_key),
        do:
          {:ok,
           %{
             bytes: 5,
             content_type: "text/plain",
             checksum: Base.encode64(:crypto.hash(:sha256, "other"))
           }}

      def read_range(_key, _first, _last), do: {:ok, "bytes"}
    end

    test "a copy whose bytes are not the source's checksum's is not kept" do
      assert Storehouse.copy("notes/a.txt", from: Lying, to: PrivateFiles) ==
               {:error, :checksum_mismatch}

      assert Storehouse.head("notes/a.txt", adapter: PrivateFiles) == {:error, :enoent}
    end

    test "refuses one store twice, and a key that is not one" do
      assert_raise ArgumentError, fn -> Storehouse.copy("a.png", from: Memory, to: Memory) end
      assert Storehouse.copy("../a.png", from: Memory, to: PrivateFiles) == {:error, :invalid_key}
      assert Storehouse.copy("none.png", from: Memory, to: PrivateFiles) == {:error, :enoent}
    end
  end

  describe "copy_prefix/2" do
    test "a thousand files, then nothing the second time" do
      for i <- 1..1_000, do: :ok = write(PrivateFiles, "batch/#{i}.txt", "file #{i}")
      :ok = write(PrivateFiles, "elsewhere/a.txt", "not this one")
      test = self()
      progress = fn key, result -> send(test, {:progress, key, result}) end

      assert Storehouse.copy_prefix("batch/",
               from: PrivateFiles,
               to: Memory,
               max_concurrency: 8,
               on_progress: progress
             ) ==
               {:ok, %{copied: 1_000, skipped: 0, failed: []}}

      assert_received {:progress, "batch/" <> _, {:ok, :copied}}
      assert Storehouse.read("batch/500.txt", adapter: Memory) == {:ok, "file 500"}
      assert Storehouse.head("elsewhere/a.txt", adapter: Memory) == {:error, :enoent}

      assert Storehouse.copy_prefix("batch/", from: PrivateFiles, to: Memory) ==
               {:ok, %{copied: 0, skipped: 1_000, failed: []}}

      # Every file, with "".
      assert {:ok, %{copied: 1, skipped: 1_000}} =
               Storehouse.copy_prefix("", from: PrivateFiles, to: Memory)
    end

    test "a file that fails is named, and the others copied" do
      :ok = write(Memory, "few/a.txt", "a")
      :ok = write(Memory, "few/b.txt", "b")
      Flaky.down()

      assert {:ok, %{copied: 0, failed: [{"few/a.txt", :down}, {"few/b.txt", :down}]}} =
               Storehouse.copy_prefix("few/", from: Memory, to: Flaky)

      Flaky.up()

      assert {:ok, %{copied: 2, failed: []}} =
               Storehouse.copy_prefix("few/", from: Memory, to: Flaky)
    end
  end

  test "mix storehouse.copy, with its progress" do
    :ok = write(PrivateFiles, "cli/a.txt", "a")
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    CopyTask.run(~w(--from StorehouseTest.PrivateFiles --to StorehouseTest.Scratch --prefix cli/))

    assert_received {:mix_shell, :info,
                     ["Copying cli/ from StorehouseTest.PrivateFiles to StorehouseTest.Scratch"]}

    assert_received {:mix_shell, :info, ["Copied 1, skipped 0 already there, 0 failed."]}
    assert Storehouse.read("cli/a.txt", adapter: Scratch) == {:ok, "a"}

    assert_raise Mix.Error, ~r/--to/, fn ->
      CopyTask.run(~w(--from StorehouseTest.Scratch))
    end
  end

  describe "Storehouse.Mirror" do
    setup do
      start_supervised!({Storehouse.Runner.Memory, backoff: fn _attempt -> 20 end})
      :ok
    end

    test "a file stored is the primary's at once, and the mirror's after" do
      {:ok, file} = Storehouse.store(@harbour, adapter: Mirrored)

      assert {:ok, _head} = Storehouse.head(file.key, adapter: PrivateFiles)
      assert file.url =~ "/private/"

      eventually(fn ->
        Storehouse.read(file.key, adapter: Flaky) == {:ok, File.read!(@harbour)}
      end)

      :ok = Storehouse.delete(file.key, adapter: Mirrored)
      assert Storehouse.head(file.key, adapter: PrivateFiles) == {:error, :enoent}
      eventually(fn -> Storehouse.head(file.key, adapter: Flaky) == {:error, :enoent} end)
    end

    test "a mirror that fails never fails the primary, and catches up when it is back" do
      # As many attempts as it takes: the mirror is back when the test says.
      stop_supervised!(Storehouse.Runner.Memory)

      start_supervised!(
        {Storehouse.Runner.Memory, backoff: fn _attempt -> 20 end, max_attempts: 10_000}
      )

      Flaky.down()
      {:ok, file} = Storehouse.store(@harbour, adapter: Mirrored)
      assert {:ok, _head} = Storehouse.head(file.key, adapter: PrivateFiles)

      Process.sleep(100)
      Flaky.up()
      eventually(fn -> match?({:ok, _head}, Storehouse.head(file.key, adapter: Flaky)) end)
    end

    test "a file uploaded straight to the primary, and one promoted, are mirrored" do
      key = "uploads/direct.jpg"
      {:ok, _url} = PrivateFiles.put(key, @harbour, %{content_type: "image/jpeg"})
      {:ok, _file} = Storehouse.verify_upload(key, adapter: Mirrored)
      eventually(fn -> match?({:ok, _head}, Storehouse.head(key, adapter: Flaky)) end)

      {:ok, cached} = Storehouse.store(@harbour, adapter: Mirrored, cache: true)
      {:ok, promoted} = Storehouse.promote(cached, adapter: Mirrored)
      eventually(fn -> match?({:ok, _head}, Storehouse.head(promoted.key, adapter: Flaky)) end)
      eventually(fn -> Storehouse.head(cached.key, adapter: Flaky) == {:error, :enoent} end)
    end

    test "without the runner's process, a mirror is written at once, its error only logged" do
      stop_supervised!(Storehouse.Runner.Memory)
      Flaky.down()

      log =
        capture_log(fn ->
          assert {:ok, file} = Storehouse.store(@harbour, adapter: Mirrored)
          assert {:ok, _head} = Storehouse.head(file.key, adapter: PrivateFiles)
        end)

      assert log =~ "StorehouseTest.Flaky failed: :down"
    end
  end

  defp write(store, key, body) do
    path =
      Path.join(System.tmp_dir!(), "storehouse-copy-body-#{System.unique_integer([:positive])}")

    File.write!(path, body)

    with {:ok, _url} <- store.put(key, path, %{content_type: "text/plain"}) do
      File.rm(path)
      :ok
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
