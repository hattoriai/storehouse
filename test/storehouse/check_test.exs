defmodule Storehouse.CheckTest do
  use ExUnit.Case, async: true

  alias Storehouse.Check

  doctest Storehouse.Check

  setup do
    dir = Path.join(System.tmp_dir!(), "storehouse-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp describe_bytes(dir, bytes, type) do
    path = Path.join(dir, "file")
    File.write!(path, bytes)
    {:ok, description} = Check.describe(path, type)
    description
  end

  test "reads PNG, GIF, JPEG and WebP sizes from the bytes", %{dir: dir} do
    png = <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 640::32, 480::32, 8, 6, 0, 0, 0>>
    gif = <<"GIF89a", 10::little-16, 20::little-16, 0, 0, 0>>

    jpeg =
      <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>> <>
        <<0xFF, 0xDB, 4::16, 0, 0>> <> <<0xFF, 0xC0, 17::16, 8, 300::16, 400::16, 3>>

    webp_x =
      <<"RIFF", 0::little-32, "WEBPVP8X", 10::little-32, 0::32, 99::little-24, 49::little-24>>

    webp_l = <<"RIFF", 0::little-32, "WEBPVP8L", 5::little-32, 0x2F, 0x0C0027::little-32>>

    assert %{content_type: "image/png", width: 640, height: 480} =
             describe_bytes(dir, png, "application/octet-stream")

    assert %{content_type: "image/gif", width: 10, height: 20} = describe_bytes(dir, gif, nil)

    assert %{content_type: "image/jpeg", width: 400, height: 300} =
             describe_bytes(dir, jpeg, "image/jpeg")

    assert %{content_type: "image/webp", width: 100, height: 50} = describe_bytes(dir, webp_x, "")
    assert %{content_type: "image/webp", width: 40, height: 49} = describe_bytes(dir, webp_l, "")
  end

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 2::32, 3::32, 8, 6, 0, 0, 0>>

  test "active and unknown claims become application/octet-stream", %{dir: dir} do
    for {bytes, claim} <- [
          {"<html><script>alert(1)</script></html>", "text/html"},
          {"<html><script>alert(1)</script></html>", "TEXT/HTML; charset=utf-8"},
          {"<html xmlns=\"http://www.w3.org/1999/xhtml\"/>", "application/xhtml+xml"},
          {"alert(1)", "text/javascript"},
          {"alert(1)", "application/javascript"},
          {"<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"/>", "image/svg+xml"},
          {"<svg/>", "image/png"},
          {"<?xml version=\"1.0\"?><x/>", "text/xml"},
          {"a,b", "text/csv"},
          {"anything", "application/x-custom"},
          {"", nil}
        ] do
      assert %{content_type: "application/octet-stream", width: nil} =
               describe_bytes(dir, bytes, claim),
             "#{inspect(claim)} was kept"
    end
  end

  test "a PDF is proven by its bytes", %{dir: dir} do
    assert %{content_type: "application/pdf", bytes: 8} =
             describe_bytes(dir, "%PDF-1.7", "application/octet-stream")

    assert %{content_type: "application/octet-stream"} =
             describe_bytes(dir, "not a pdf", "application/pdf")
  end

  # The start of a WebM file: the EBML header, with the "webm" DocType.
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42,
          0xF2, 0x81, 0x04, 0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x84, "webm", 0x42, 0x87, 0x81,
          0x04, 0x42, 0x85, 0x81, 0x02, 0x18, 0x53, 0x80, 0x67>>

  defp ftyp(major, compatible) do
    body = major <> <<0::32>> <> Enum.join(compatible)
    <<8 + byte_size(body)::32, "ftyp", body::binary, 0, 0, 0, 8, "free">>
  end

  test "MP4 and WebM videos are proven by their bytes", %{dir: dir} do
    assert %{content_type: "video/webm", width: nil} = describe_bytes(dir, @webm, nil)
    assert %{content_type: "video/mp4"} = describe_bytes(dir, ftyp("isom", ["isom", "avc1"]), "")
    assert %{content_type: "video/mp4"} = describe_bytes(dir, ftyp("abcd", ["mp42"]), "")

    matroska = :binary.replace(@webm, "webm", "mkvx")

    for {bytes, claim} <- [
          {matroska, "video/webm"},
          {ftyp("qt  ", ["qt  "]), "video/quicktime"},
          {ftyp("M4A ", ["isom"]), "video/mp4"},
          {ftyp("heic", ["mif1"]), "video/mp4"},
          {ftyp("abcd", ["abcd"]), "video/mp4"},
          {<<0x1A, 0x45, 0xDF, 0xA3>>, "video/webm"},
          {<<0::32, "ftyp">>, "video/mp4"},
          {"not a video", "video/mp4"}
        ] do
      assert %{content_type: "application/octet-stream"} = describe_bytes(dir, bytes, claim),
             "#{inspect(bytes)} is not a video"
    end
  end

  test "a renamed PNG is a PNG, whatever the claim", %{dir: dir} do
    for claim <- ["text/html", "image/svg+xml", "application/pdf", nil] do
      assert %{content_type: "image/png", width: 2, height: 3} = describe_bytes(dir, @png, claim)
    end
  end

  test "text/plain needs the claim and valid UTF-8 with no NUL", %{dir: dir} do
    assert %{content_type: "text/plain"} = describe_bytes(dir, "héllo", "text/plain")

    assert %{content_type: "text/plain"} =
             describe_bytes(dir, "héllo", "text/plain; charset=utf-8")

    assert %{content_type: "application/octet-stream"} = describe_bytes(dir, "héllo", nil)

    assert %{content_type: "application/octet-stream"} =
             describe_bytes(dir, <<"a", 0, "b">>, "text/plain")

    assert %{content_type: "application/octet-stream"} =
             describe_bytes(dir, <<0xFF, 0xFE>>, "text/plain")
  end

  test "a long text file may cut a character at the end of the head", %{dir: dir} do
    text = String.duplicate("a", 65_535) <> "é" <> "more"
    assert %{content_type: "text/plain"} = describe_bytes(dir, text, "text/plain")
  end

  test "ZIP and Office files by their signatures", %{dir: dir} do
    docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    zip = <<"PK", 3, 4, "rest">>
    ole = <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, "rest">>

    assert %{content_type: ^docx} = describe_bytes(dir, zip, docx)
    assert %{content_type: "application/zip"} = describe_bytes(dir, zip, "text/html")
    assert %{content_type: "application/msword"} = describe_bytes(dir, ole, "application/msword")
    assert %{content_type: "application/octet-stream"} = describe_bytes(dir, ole, "text/html")
    assert %{content_type: "application/octet-stream"} = describe_bytes(dir, "no", docx)
  end

  test "every checked type has an extension, and content_type/1 reverses it" do
    for type <- ["image/png", "application/pdf", "text/plain", "application/zip"] do
      assert type |> Check.extension() |> Check.content_type() == type
    end

    assert Check.content_type(".PNG") == "image/png"
    assert Check.content_type(".html") == "application/octet-stream"
  end

  test "describe/2 gives an error for a missing file" do
    assert {:error, :enoent} = Check.describe("/no/such/file", "text/plain")
  end

  test "clean_name/1 limits the length and never gives an empty name" do
    assert String.length(Storehouse.clean_name(String.duplicate("é", 300))) == 200
    assert Storehouse.clean_name("\u0000") == "file"
    assert Storehouse.clean_name(<<0xFF, "a">>) == "a"
    assert Storehouse.clean_name(nil) == "file"
    assert Storehouse.clean_name("a\u200Eb\u2066c\u2069\uFEFF.pdf") == "abc.pdf"
  end

  describe "Storehouse.store/2" do
    defmodule RecordingStorage do
      @moduledoc false
      @behaviour Storehouse.Adapter

      @impl true
      def put(key, path, meta) do
        send(self(), {:put, key, File.read!(path), meta})
        {:ok, url(key)}
      end

      @impl true
      def url(key), do: "/files/" <> key

      @impl true
      def delete(key), do: send(self(), {:deleted, key})
    end

    @png <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 1280::32, 800::32, 8, 6, 0, 0, 0>>

    test "stores a file and returns it, as an upload makes it", %{dir: dir} do
      path = Path.join(dir, "Timeline view.png")
      File.write!(path, @png)

      assert {:ok, %Storehouse.File{} = node} = Storehouse.store(path, adapter: RecordingStorage)

      assert %Storehouse.File{
               name: "Timeline view.png",
               content_type: "image/png",
               width: 1280,
               height: 800,
               bytes: 29
             } = node

      assert node.key =~ ~r"^\d{4}/\d{2}/[0-9a-f-]+-Timeline_view\.png$"
      assert node.url == "/files/" <> node.key
      assert_received {:put, key, @png, %{name: "Timeline view.png", content_type: "image/png"}}
      assert key == node.key
      assert File.exists?(path)
    end

    test "takes a name, a key and a preview", %{dir: dir} do
      path = Path.join(dir, "shot")
      File.write!(path, @png)

      assert {:ok, node} =
               Storehouse.store(path,
                 adapter: RecordingStorage,
                 name: "Share dialog.png",
                 key: fn name, type -> "seeds/" <> name <> "." <> type end,
                 preview: fn node, ^path -> "/previews/" <> node.key end
               )

      assert node.key == "seeds/Share dialog.png.image/png"
      assert node.preview == "/previews/" <> node.key
    end

    test "the bytes make the type: a page named .png is not an image", %{dir: dir} do
      path = Path.join(dir, "page.png")
      File.write!(path, "<html><script>alert(1)</script></html>")

      assert {:ok, node} = Storehouse.store(path, adapter: RecordingStorage)
      assert node.content_type == "application/octet-stream"
      assert node.key =~ ~r"\.bin$"
    end

    test "deletes the stored file when the store gives an unsafe URL", %{dir: dir} do
      path = Path.join(dir, "a.png")
      File.write!(path, @png)

      defmodule UnsafeUrlStorage do
        @moduledoc false
        @behaviour Storehouse.Adapter
        @impl true
        def put(_key, _path, _meta), do: {:ok, "javascript:alert(1)"}
        @impl true
        def url(_key), do: "javascript:alert(1)"
        @impl true
        def delete(key), do: send(self(), {:deleted, key})
      end

      assert {:error, {:unsafe_url, "javascript:alert(1)"}} =
               Storehouse.store(path, adapter: UnsafeUrlStorage)

      assert_received {:deleted, _key}
    end

    test "returns the error of a missing file or a bad key", %{dir: dir} do
      assert {:error, :enoent} =
               Storehouse.store(Path.join(dir, "nope.png"), adapter: RecordingStorage)

      path = Path.join(dir, "a.png")
      File.write!(path, @png)

      assert {:error, {:invalid_key, nil}} =
               Storehouse.store(path, adapter: RecordingStorage, key: fn _, _ -> nil end)

      refute_received {:put, _, _, _}
    end
  end
end
