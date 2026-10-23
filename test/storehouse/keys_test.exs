defmodule Storehouse.KeysTest do
  use ExUnit.Case, async: false

  alias Storehouse, as: Storage

  describe "key/1" do
    test "is yyyy/mm/<uuid>-<safe name> for this month" do
      now = DateTime.utc_now()
      key = Storage.key("cat.png", "image/png")

      assert [year, month, file] = String.split(key, "/")
      assert year == Integer.to_string(now.year)
      assert month == now.month |> Integer.to_string() |> String.pad_leading(2, "0")

      assert file =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}-cat\.png\z/

      assert Storage.valid_key?(key)
    end

    test "is new each time" do
      refute Storage.key("a", "text/plain") == Storage.key("a", "text/plain")
    end

    test "is valid for any name" do
      for name <- ["../../x", "..", ".", "", "a/b\\c", "名前.txt", String.duplicate("x", 500)] do
        key = Storage.key(name, "application/octet-stream")
        assert Storage.valid_key?(key), "not valid for #{inspect(name)}"
        assert String.ends_with?(key, ".bin")
      end
    end
  end

  describe "safe_name/2" do
    test "keeps only safe characters, and at most 100" do
      assert Storage.safe_name("a b/c\\d:e.txt", "text/plain") == "a_b_c_d_e.txt"
      assert Storage.safe_name("..", "text/plain") == "file.txt"
      assert Storage.safe_name("a.", "image/gif") == "a.gif"

      long = Storage.safe_name(String.duplicate("x", 300) <> ".jpeg", "image/jpeg")
      assert byte_size(long) == 100
      assert String.ends_with?(long, "xx.jpg")
    end

    test "never keeps the client's extension" do
      for {name, type} <- [
            {"x.svg", "application/octet-stream"},
            {"x.html", "application/octet-stream"},
            {"x.html", "text/plain"},
            {"x.png.html", "image/png"},
            {"x.SVG", "image/png"}
          ] do
        safe = Storage.safe_name(name, type)
        assert Path.extname(safe) == Storehouse.Check.extension(type), "#{name} gave #{safe}"
        refute safe =~ ~r/\.(svg|html)\z/i
      end

      refute "x.svg" |> Storage.key("application/octet-stream") |> String.ends_with?(".svg")
    end
  end

  describe "valid_key?/1" do
    test "refuses keys that can leave the root" do
      for key <- [
            "",
            "/",
            "a//b",
            "a/",
            "..",
            "a/../b",
            "./a",
            "a\\b",
            "a/b\u0000",
            "~/a",
            nil,
            1
          ] do
        refute Storage.valid_key?(key), "valid: #{inspect(key)}"
      end

      refute Storage.valid_key?(String.duplicate("a", 256))
    end
  end

  test "adapter/0 is Storehouse.Local by default, and the config's" do
    assert Storage.adapter() == Storehouse.Local
    Application.put_env(:storehouse, :adapter, MyApp.Storage)
    assert Storage.adapter() == MyApp.Storage
  after
    Application.delete_env(:storehouse, :adapter)
  end
end
