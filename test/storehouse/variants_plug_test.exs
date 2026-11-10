defmodule Storehouse.VariantsPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Storehouse.Memory
  alias Storehouse.Variants.Plug, as: VariantsPlug
  alias Vix.Vips.Image

  @fixtures Path.expand("../fixtures", __DIR__)
  @presets [
    thumb: [width: 320],
    photo: [widths: [320, 640], format: [:webp, :original]]
  ]
  @opts [presets: @presets, adapter: Memory]

  setup do
    Memory.checkout()
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory)
    %{original: file}
  end

  defp get(path, headers \\ [], opts \\ @opts) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, conn -> put_req_header(conn, k, v) end)

    VariantsPlug.call(conn, VariantsPlug.init(opts))
  end

  test "made and sent, for a CDN to keep for a year", %{original: file} do
    conn = get(Storehouse.variant_url(file, :thumb, @opts))

    assert conn.status == 200
    assert conn.halted
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "vary") == []
    {:ok, image} = Image.new_from_buffer(conn.resp_body)
    assert Image.width(image) == 320

    head = VariantsPlug.call(conn(:head, Storehouse.variant_url(file, :thumb, @opts)), @opts)
    assert head.status == 200
    assert head.resp_body == ""
  end

  test "tagged with its original's cache tag, when asked", %{original: file} do
    url = Storehouse.variant_url(file, :thumb, @opts)

    assert get(url, [], Keyword.put(@opts, :cache_tag, true)) |> get_resp_header("cache-tag") ==
             [Storehouse.Purge.cache_tag(file.key)]

    assert get(url) |> get_resp_header("cache-tag") == []
  end

  test "in the format the browser takes", %{original: file} do
    url = Storehouse.variant_url(file, :photo, Keyword.put(@opts, :width, 320))

    webp = get(url, [{"accept", "image/avif,image/webp,*/*"}])
    assert get_resp_header(webp, "content-type") == ["image/webp"]
    assert get_resp_header(webp, "vary") == ["Accept"]

    jpeg = get(url, [{"accept", "*/*"}])
    assert get_resp_header(jpeg, "content-type") == ["image/jpeg"]
    assert get_resp_header(jpeg, "vary") == ["Accept"]
  end

  test "only the presets' sizes", %{original: file} do
    url = Storehouse.variant_url(file, :photo, Keyword.put(@opts, :width, 320))
    [_, fingerprint] = Regex.run(~r/-([0-9a-f]{8})\z/, url)

    for path <- [
          "/variants/#{file.key}/photo-321-#{fingerprint}",
          "/variants/#{file.key}/huge-320-#{fingerprint}",
          "/variants/#{file.key}/photo-320",
          "/variants/#{file.key}/photo-320-#{fingerprint}.webp",
          "/variants/../#{file.key}/photo-320-#{fingerprint}",
          "/variants/photo-320-#{fingerprint}"
        ] do
      assert get(path).status == 404, path
    end
  end

  test "a preset since changed is sent to its current URL", %{original: file} do
    old = Storehouse.variant_url(file, :thumb, presets: [thumb: [width: 320, quality: 50]])
    conn = get(old)

    assert conn.status == 302
    assert get_resp_header(conn, "location") == [Storehouse.variant_url(file, :thumb, @opts)]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end

  test "no original, no image, no variant of a variant", %{original: file} do
    {:ok, thumb} = Storehouse.variant(file, :thumb, @opts)

    path = Path.join(System.tmp_dir!(), "words-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "Not a photograph.")
    on_exit(fn -> File.rm(path) end)
    {:ok, text} = Storehouse.store(path, adapter: Memory)

    for key <- ["2026/10/none.jpg", text.key, thumb.key] do
      assert get(Storehouse.variant_url(key, :thumb, @opts)).status == 404, key
    end
  end

  test "only the originals it is given", %{original: file} do
    url = Storehouse.variant_url(file, :thumb, @opts)

    assert get(url, [], Keyword.put(@opts, :only, ["public/"])).status == 404
    assert get(url, [], Keyword.put(@opts, :only, ["2026/", "20"])).status == 200
    assert get(url, [], Keyword.put(@opts, :only, &String.ends_with?(&1, ".png"))).status == 404
  end

  test "under a path of its own, and every other request passed on", %{original: file} do
    "/variants" <> rest = Storehouse.variant_url(file, :thumb, @opts)

    assert get("/img" <> rest, [], Keyword.put(@opts, :at, "/img")).status == 200
    refute get("/img" <> rest).halted
    refute VariantsPlug.call(conn(:post, "/variants" <> rest), @opts).halted
  end

  describe "a file's own crop" do
    @secret String.duplicate("s", 32)
    @crop_opts [
      presets: [avatar: [width: 100, height: 100, fit: :cover]],
      adapter: Memory,
      secret: @secret
    ]

    test "made from its signed URL", %{original: file} do
      url = Storehouse.variant_url(file, :avatar, @crop_opts ++ [crop: {0.5, 0.5, 0.5, 0.5}])
      conn = get(url, [], @crop_opts)

      assert conn.status == 200
      {:ok, image} = Image.new_from_buffer(conn.resp_body)
      assert {Image.width(image), Image.height(image)} == {100, 100}
    end

    test "not without its signature, or with another's", %{original: file} do
      url = Storehouse.variant_url(file, :avatar, @crop_opts ++ [crop: {0.5, 0.5, 0.5, 0.5}])
      [path, _query] = String.split(url, "?")
      other = Storehouse.variant_url(file, :avatar, @crop_opts ++ [crop: {0, 0, 0.5, 0.5}])
      [_, other_sig] = String.split(other, "&sig=")

      for bad <- [
            path <> "?crop=0.5,0.5,0.5,0.5",
            path <> "?crop=0.5,0.5,0.5,0.5&sig=" <> other_sig,
            path <> "?crop=0.50,0.5,0.5,0.5&" <> (url |> String.split("&") |> List.last())
          ] do
        assert get(bad, [], @crop_opts).status == 404, bad
      end

      assert get(url, [], Keyword.delete(@crop_opts, :secret)).status == 404
    end

    test "a preset since changed is sent to its current URL, with its crop", %{original: file} do
      crop = {0.5, 0.5, 0.5, 0.5}

      old =
        Storehouse.variant_url(
          file,
          :avatar,
          Keyword.put(@crop_opts, :presets,
            avatar: [width: 100, height: 100, fit: :cover, quality: 50]
          ) ++
            [crop: crop]
        )

      conn = get(old, [], @crop_opts)
      assert conn.status == 302

      assert get_resp_header(conn, "location") ==
               [Storehouse.variant_url(file, :avatar, @crop_opts ++ [crop: crop])]
    end
  end
end
