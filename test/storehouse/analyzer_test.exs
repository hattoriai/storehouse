defmodule Storehouse.AnalyzerTest do
  use ExUnit.Case, async: true

  alias Storehouse.Memory
  alias StorehouseTest.Analyzers.{Bytes, Fail, Head, NoFile, Skip}

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  setup do
    Memory.checkout()
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory)
    %{stored: file}
  end

  defp analyze(file, steps, opts \\ []),
    do: Storehouse.analyze(file, steps, Keyword.put(opts, :adapter, Memory))

  test "runs the steps in order, each result under its name", %{stored: file} do
    test = self()
    assert {:ok, file} = analyze(file, [{Bytes, test: test}, {Head, test: test}, Skip])

    assert Storehouse.File.analyzed(file, "bytes") == %{"bytes" => 35_367}
    assert Storehouse.File.analyzed(file, "first_byte") == %{"value" => 0xFF}
    assert Storehouse.File.analyzed(file, "skip") == %{"skipped" => true}

    # Read from the store once, to one temporary file, removed after them.
    assert_received {:bytes, _key, path, true}
    assert_received {:head, ^path}
    refute File.exists?(path)
  end

  test "a step that does not need the file reads nothing", %{stored: file} do
    Memory.fail_next(:read_range, :must_not_read)

    assert {:ok, file} = analyze(file, [{NoFile, test: self()}, Storehouse.Analyzer.Size])
    assert_received {:no_file, nil}

    assert Storehouse.File.analyzed(file, "size") == %{
             "bytes" => 35_367,
             "content_type" => "image/jpeg"
           }
  end

  test "a step that fails keeps why, and leaves the others' results", %{stored: file} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :analyze, :stop]])

    assert {:ok, file} =
             analyze(file, [
               {Fail, how: :raise},
               NoFile,
               {Fail, how: :error},
               Storehouse.Analyzer.Size
             ])

    assert Storehouse.File.analyzed(file, "fail") == %{"error" => ":no_tool"}
    assert Storehouse.File.analyzed(file, "no_file") == %{"ran" => true}
    assert Storehouse.File.analyzed(file, "size")["bytes"] == 35_367

    assert_received {[:storehouse, :analyze, :stop], ^ref, _m,
                     %{step: "fail", result: :error, reason: "the tool crashed"}}

    assert_received {[:storehouse, :analyze, :stop], ^ref, _m, %{step: "no_file", result: :ok}}
  end

  test "a step done is not run again, unless forced; one that failed is", %{stored: file} do
    test = self()
    {:ok, file} = analyze(file, [{NoFile, test: test}, {Fail, test: test}])
    assert_received {:no_file, nil}
    assert_received :fail_ran

    {:ok, file} = analyze(file, [{NoFile, test: test}, {Fail, test: test}])
    refute_received {:no_file, nil}
    assert_received :fail_ran

    {:ok, _file} = analyze(file, [{NoFile, test: test}], force: true)
    assert_received {:no_file, nil}
  end

  test "a file that cannot be read for the steps is an error", %{stored: file} do
    :ok = Storehouse.delete(file.key, adapter: Memory)
    assert analyze(file, [Bytes]) == {:error, :enoent}
  end

  test "store/2 with :analyze reads the file from its path, with no download" do
    Memory.fail_next(:read_range, :must_not_read)

    assert {:ok, file} =
             Storehouse.store(@harbour, adapter: Memory, analyze: [{Bytes, test: self()}])

    assert_received {:bytes, _key, @harbour, true}
    assert Storehouse.File.analyzed(file, "bytes") == %{"bytes" => 35_367}
  end

  describe "analyze_later/3" do
    test "without Storehouse.Tasks, runs at once, then the app's function", %{stored: file} do
      assert :ok =
               Storehouse.analyze_later(file, [NoFile],
                 adapter: Memory,
                 then: {StorehouseTest.Analyzers, :done, [self()]}
               )

      assert_received {:analyzed, analyzed}
      assert Storehouse.File.analyzed(analyzed, "no_file") == %{"ran" => true}
    end

    test "with Storehouse.Tasks, in a task that sees the test's files", %{stored: file} do
      start_supervised!({Storehouse.Tasks, max_children: 2})

      assert :ok =
               Storehouse.analyze_later(file, [Bytes],
                 adapter: Memory,
                 then: {StorehouseTest.Analyzers, :done, [self()]}
               )

      assert_receive {:analyzed, analyzed}, 1_000
      assert Storehouse.File.analyzed(analyzed, "bytes") == %{"bytes" => 35_367}
    end

    test "a file that cannot be read gives the app's function nothing", %{stored: file} do
      :ok = Storehouse.delete(file.key, adapter: Memory)

      assert Storehouse.analyze_later(file, [Bytes],
               adapter: Memory,
               then: {StorehouseTest.Analyzers, :done, [self()]}
             ) == :ok

      refute_received {:analyzed, _file}
    end
  end

  test "names" do
    assert Storehouse.Analyzer.name(Bytes) == "bytes"
    assert Storehouse.Analyzer.name({Head, []}) == "first_byte"
    assert Storehouse.Analyzer.name(Storehouse.Analyzer.Size) == "size"
  end
end
