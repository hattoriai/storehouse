defmodule Storehouse.LocalTest do
  # The root is application config.
  use ExUnit.Case, async: false

  alias Storehouse.Local

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-local-#{System.unique_integer([:positive])}")

    source =
      Path.join(System.tmp_dir!(), "storehouse-source-#{System.unique_integer([:positive])}")

    File.write!(source, "file body")
    Application.put_env(:storehouse, Storehouse.Local, root: root, url_prefix: "/files/")

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
      File.rm(source)
    end)

    %{root: root, source: source}
  end

  test "put/3 copies the file under the key and returns its URL", %{root: root, source: source} do
    key = Storehouse.key("notes.txt", "text/plain")

    assert {:ok, url} = Local.put(key, source, %{name: "notes.txt"})
    assert url == "/files/" <> key
    assert File.read!(Path.join(root, key)) == "file body"
    assert File.exists?(source)
  end

  test "put/3 refuses a key that is not valid", %{root: root, source: source} do
    for key <- ["../escape.txt", "a/../../escape.txt", "/tmp/escape.txt", ""] do
      assert Local.put(key, source, %{}) == {:error, :invalid_key}
    end

    refute File.exists?(Path.join(Path.dirname(root), "escape.txt"))
  end

  test "put/3 gives an error when the source is missing" do
    assert {:error, :enoent} = Local.put("a/b.txt", "/no/such/file", %{})
  end

  # Written beside the key and renamed into place: no part of a file at its
  # key, and nothing left beside it, whatever happens.
  test "put/3 leaves no file at the key, nor beside it, when it fails", %{root: root} do
    directory =
      Path.join(System.tmp_dir!(), "storehouse-dir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, _reason} = Local.put("2026/11/a.txt", directory, %{})
    assert {:error, :enoent} = Local.put("2026/11/b.txt", "/no/such/file", %{})
    assert File.ls!(Path.join(root, "2026/11")) == []
  end

  test "put/3 leaves only the file, and a second put of the key replaces it whole",
       %{root: root, source: source} do
    assert {:ok, _url} = Local.put("2026/11/a.txt", source, %{})
    File.write!(source, "a longer file body")
    assert {:ok, _url} = Local.put("2026/11/a.txt", source, %{})

    assert File.ls!(Path.join(root, "2026/11")) == ["a.txt"]
    assert File.read!(Path.join(root, "2026/11/a.txt")) == "a longer file body"
  end

  test "url/1 uses the default prefix" do
    Application.put_env(:storehouse, Storehouse.Local, root: "tmp")
    assert Local.url("2026/09/a.png") == "/uploads/2026/09/a.png"
  end

  test "delete/1 removes the file, and a missing file is :ok", %{root: root, source: source} do
    {:ok, _url} = Local.put("2026/09/x.txt", source, %{})

    assert Local.delete("2026/09/x.txt") == :ok
    refute File.exists?(Path.join(root, "2026/09/x.txt"))
    assert Local.delete("2026/09/x.txt") == :ok
    assert Local.delete("../x") == {:error, :invalid_key}
  end

  test "path/1 is under the root", %{root: root} do
    assert {:ok, path} = Local.path("2026/09/x.txt")
    assert path == Path.join(Path.expand(root), "2026/09/x.txt")
  end

  test "root/0 raises without a configured root" do
    Application.delete_env(:storehouse, Storehouse.Local)
    assert_raise ArgumentError, ~r/needs a root directory/, fn -> Local.root() end
  end
end
