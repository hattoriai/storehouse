defmodule Storehouse.VariantsTest do
  use ExUnit.Case, async: true

  alias Storehouse.Memory
  alias StorehouseTest.Renderers.{Counting, Urls}
  alias Vix.Vips.{Image, Operation}

  @fixtures Path.expand("../fixtures", __DIR__)
  @presets [
    thumb: [width: 320],
    square: [width: 100, height: 100, fit: :cover, focus: :attention],
    corner: [width: 100, height: 100, fit: :cover, focus: {0, 0}],
    photo: [widths: [320, 640, 2000], format: [:webp, :original]],
    banner: [widths: [300, 600], aspect: {3, 1}, fit: :cover],
    flat: [width: 64, format: :jpeg, background: "#000000"],
    kept: [width: 64, metadata: :all]
  ]

  setup do
    Memory.checkout()
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory)
    %{original: file}
  end

  defp opts(extra \\ []), do: Keyword.merge([presets: @presets, adapter: Memory], extra)

  defp size(file) do
    {:ok, bytes} = Storehouse.read(file.key, adapter: Memory)
    {:ok, image} = Image.new_from_buffer(bytes)
    {Image.width(image), Image.height(image)}
  end

  describe "variant_url/3" do
    test "the same every time, under the original's key", %{original: file} do
      url = Storehouse.variant_url(file, :thumb, opts())
      assert url == Storehouse.variant_url(file.key, :thumb, opts())
      assert url =~ ~r"\A/variants/#{Regex.escape(file.key)}/thumb-320-[0-9a-f]{8}\z"
    end

    test "a width asked for is the preset's as wide, or the next up, or its widest", %{
      original: file
    } do
      assert Storehouse.variant_url(file, :photo, opts(width: 500)) =~ "/photo-640-"
      assert Storehouse.variant_url(file, :photo, opts(width: 640)) =~ "/photo-640-"
      assert Storehouse.variant_url(file, :photo, opts(width: 9_000)) =~ "/photo-2000-"
      assert Storehouse.variant_url(file, :photo, opts()) =~ "/photo-2000-"
    end

    test "a preset changed is a new URL", %{original: file} do
      before = Storehouse.variant_url(file, :thumb, opts())

      changed =
        Storehouse.variant_url(file, :thumb, opts(presets: [thumb: [width: 320, quality: 70]]))

      assert before != changed
    end

    test "at the configured address", %{original: file} do
      assert Storehouse.variant_url(file, :thumb, opts(url: "https://cdn.example.com/v/")) =~
               ~r"\Ahttps://cdn.example.com/v/#{Regex.escape(file.key)}/thumb-320-"
    end

    test "a renderer's own URLs", %{original: file} do
      assert Storehouse.variant_url(file, :photo, opts(renderer: Urls, width: 600)) ==
               "https://images.example.com/photo/640/#{file.key}"
    end

    test "a focus of its own only for a renderer of URLs, which signs it", %{original: file} do
      assert_raise ArgumentError, ~r/renderer of URLs/, fn ->
        Storehouse.variant_url(file, :corner, opts(focus: {0.5, 0.5}))
      end
    end

    test "a preset not configured, or not right, raises", %{original: file} do
      assert_raise ArgumentError, ~r/no preset/, fn ->
        Storehouse.variant_url(file, :none, opts())
      end

      for {preset, message} <- [
            {[], ~r/:width or :widths/},
            {[widths: [100, 200], height: 50], ~r/:aspect/},
            {[width: 100, fit: :cover], ~r/:cover needs/},
            {[width: 100, format: :bmp], ~r/:format/},
            {[width: 100, quality: 0], ~r/:quality/},
            {[width: 100, focus: {2, 0}], ~r/:focus/},
            {[width: 100, size: 3], ~r/unknown keys/}
          ] do
        assert_raise ArgumentError, message, fn ->
          Storehouse.variant_url(file, :bad, opts(presets: [bad: preset]))
        end
      end

      assert_raise ArgumentError, ~r/name/, fn ->
        Storehouse.variant_url(file, :Bad, opts(presets: [Bad: [width: 10]]))
      end
    end
  end

  describe "variant/3" do
    test "made and stored beside its original, then found", %{original: file} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :variant, :stop]])

      assert {:ok, thumb} = Storehouse.variant(file, :thumb, opts())
      assert String.starts_with?(thumb.key, "variants/#{file.key}/thumb-320-")
      assert String.ends_with?(thumb.key, ".jpg")
      assert {thumb.width, thumb.height} == {320, 213}
      assert thumb.content_type == "image/jpeg"
      assert size(thumb) == {320, 213}
      assert_received {[:storehouse, :variant, :stop], ^ref, _, %{result: :made}}

      assert {:ok, found} = Storehouse.variant(file, :thumb, opts())
      assert found.key == thumb.key
      assert found.bytes == thumb.bytes
      assert_received {[:storehouse, :variant, :stop], ^ref, _, %{result: :found}}
    end

    test "never larger than the original", %{original: file} do
      {:ok, photo} = Storehouse.variant(file, :photo, opts())
      assert size(photo) == {1200, 800}
    end

    test "cropped to its box, around what stands out or a point", %{original: file} do
      {:ok, square} = Storehouse.variant(file, :square, opts())
      assert size(square) == {100, 100}

      {:ok, corner} = Storehouse.variant(file, :corner, opts())
      assert size(corner) == {100, 100}

      {:ok, banner} = Storehouse.variant(file, :banner, opts(width: 600))
      assert size(banner) == {600, 200}
    end

    test "turned as its EXIF says" do
      {:ok, turned} = Storehouse.store(Path.join(@fixtures, "turned.jpg"), adapter: Memory)
      {:ok, thumb} = Storehouse.variant(turned, :thumb, opts(presets: [thumb: [width: 4]]))
      {width, height} = size(thumb)
      assert width < height
    end

    test "in the format the browser takes, each kept apart", %{original: file} do
      {:ok, webp} =
        Storehouse.variant(file, :photo, opts(width: 320, accept: "image/avif,image/webp,*/*"))

      {:ok, jpeg} = Storehouse.variant(file, :photo, opts(width: 320, accept: "image/png,*/*"))
      {:ok, chosen} = Storehouse.variant(file, :photo, opts(width: 320, format: :webp))

      assert webp.content_type == "image/webp"
      assert String.ends_with?(webp.key, ".webp")
      assert jpeg.content_type == "image/jpeg"
      assert webp.key != jpeg.key
      assert chosen.key == webp.key
    end

    test "none of the original's metadata, unless the preset keeps it" do
      {:ok, camera} = Storehouse.store(Path.join(@fixtures, "exif/camera.jpg"), adapter: Memory)
      assert {:ok, original} = Storehouse.read(camera, adapter: Memory)
      assert original =~ "Exif"

      {:ok, thumb} = Storehouse.variant(camera, :thumb, opts(presets: [thumb: [width: 8]]))
      {:ok, bytes} = Storehouse.read(thumb, adapter: Memory)
      refute bytes =~ "Exif"

      {:ok, kept} = Storehouse.variant(camera, :kept, opts())
      {:ok, bytes} = Storehouse.read(kept, adapter: Memory)
      assert bytes =~ "Exif"
    end

    test "transparency laid on the background in a JPEG" do
      {:ok, png} = Storehouse.store(Path.join(@fixtures, "exif/photo.png"), adapter: Memory)
      {:ok, flat} = Storehouse.variant(png, :flat, opts())
      assert flat.content_type == "image/jpeg"

      {:ok, kept} = Storehouse.variant(png, :thumb, opts())
      assert kept.content_type == "image/png"
      {:ok, bytes} = Storehouse.read(kept, adapter: Memory)
      {:ok, image} = Image.new_from_buffer(bytes)
      assert Image.has_alpha?(image)
    end

    test "made once, however many ask at the same time", %{original: file} do
      opts = opts(renderer: {Counting, test: self(), sleep: 200})

      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> Storehouse.variant(file, :thumb, opts) end) end)
        |> Task.await_many(30_000)

      assert [{:ok, %{key: key}}] = Enum.uniq_by(results, fn {:ok, file} -> file.key end)
      assert String.ends_with?(key, ".jpg")
      assert_received {:rendered, _node, :thumb, 320}
      refute_received {:rendered, _node, _preset, _width}
    end

    test "a caller waits no longer than its timeout", %{original: file} do
      test = self()
      opts = opts(renderer: {Counting, test: test, sleep: 500})
      first = Task.async(fn -> Storehouse.variant(file, :thumb, opts) end)
      # Drawing: under a busy suite, it may take a while to start.
      assert_receive {:rendered, _node, :thumb, 320}, 2_000

      assert {:error, :timeout} =
               Storehouse.variant(file, :thumb, Keyword.put(opts, :timeout, 50))

      assert {:ok, _thumb} = Task.await(first)
    end

    test "a missing original" do
      assert {:error, :enoent} = Storehouse.variant("2026/10/none.jpg", :thumb, opts())
    end

    test "an original libvips cannot read", %{original: file} do
      {:ok, bytes} = Storehouse.read(file, adapter: Memory)
      path = Path.join(System.tmp_dir!(), "cut-#{System.unique_integer([:positive])}.jpg")
      File.write!(path, binary_part(bytes, 0, 200))
      on_exit(fn -> File.rm(path) end)
      {:ok, cut} = Storehouse.store(path, adapter: Memory)

      assert {:error, reason} = Storehouse.variant(cut, :thumb, opts())
      assert is_binary(reason)
    end

    test "an original of more pixels than the renderer takes, by its header", %{original: file} do
      # harbour.jpg is 1200 × 800: past 900,000 pixels.
      small = opts(renderer: {Storehouse.Renderer.Vix, max_pixels: 900_000})
      assert {:error, :too_large} = Storehouse.variant(file, :thumb, small)
      assert {:ok, _thumb} = Storehouse.variant(file, :thumb, opts())
    end

    test "a renderer of URLs makes none", %{original: file} do
      assert {:error, :not_supported} = Storehouse.variant(file, :thumb, opts(renderer: Urls))
    end
  end

  describe "a file's own crop" do
    @secret String.duplicate("s", 32)

    defp mean(%Image{} = image) do
      {:ok, mean} = Operation.avg(image)
      mean
    end

    defp mean_of(file) do
      {:ok, bytes} = Storehouse.read(file.key, adapter: Memory)
      {:ok, image} = Image.new_from_buffer(bytes)
      mean(image)
    end

    test "in the plug's URL, signed, its own variant", %{original: file} do
      plain = Storehouse.variant_url(file, :square, opts())

      url =
        Storehouse.variant_url(file, :square, opts(secret: @secret, crop: {0.5, 0.25, 0.5, 0.5}))

      assert url =~ ~r"/square-100-[0-9a-f]{8}\?crop=0\.5,0\.25,0\.5,0\.5&sig=[\w-]{22}\z"
      refute String.starts_with?(url, plain)

      other = Storehouse.variant_url(file, :square, opts(secret: @secret, crop: {0, 0, 0.5, 0.5}))
      assert other != url
    end

    test "no crop, the URL of before", %{original: file} do
      assert Storehouse.variant_url(file, :square, opts(secret: @secret)) ==
               Storehouse.variant_url(file, :square, opts())

      assert Storehouse.variant_url(file, :square, opts(crop: nil)) ==
               Storehouse.variant_url(file, :square, opts())
    end

    test "kept to four decimals: one crop, one URL", %{original: file} do
      assert Storehouse.variant_url(
               file,
               :square,
               opts(secret: @secret, crop: {0.1, 0.1, 0.5, 0.5})
             ) ==
               Storehouse.variant_url(
                 file,
                 :square,
                 opts(secret: @secret, crop: {0.100004, 0.1, 0.5, 0.49999999})
               )
    end

    test "needs the secret in the plug's URLs, not a renderer's own", %{original: file} do
      assert_raise ArgumentError, ~r/:secret/, fn ->
        Storehouse.variant_url(file, :square, opts(crop: {0, 0, 0.5, 0.5}))
      end

      assert Storehouse.variant_url(file, :photo, opts(renderer: Urls, crop: {0, 0, 0.5, 0.5}))
    end

    test "inside the original, or it raises", %{original: file} do
      for crop <- [{-0.1, 0, 0.5, 0.5}, {0, 0, 0, 0.5}, {0.6, 0, 0.5, 0.5}, {0, 0, 0.5}, :all] do
        assert_raise ArgumentError, ~r/:crop/, fn ->
          Storehouse.variant_url(file, :square, opts(secret: @secret, crop: crop))
        end
      end
    end

    test "made of that part of the original only", %{original: file} do
      {:ok, original} = Image.new_from_file(Path.join(@fixtures, "harbour.jpg"))

      for {crop, {left, top, width, height}} <- [
            {{0, 0, 0.5, 0.5}, {0, 0, 600, 400}},
            {{0.5, 0.5, 0.5, 0.5}, {600, 400, 600, 400}}
          ] do
        {:ok, square} = Storehouse.variant(file, :square, opts(crop: crop))
        assert size(square) == {100, 100}

        # Filled from the crop's middle: a 400 × 400 square of it.
        {:ok, part} =
          Operation.extract_area(
            original,
            left + div(width - height, 2),
            top,
            height,
            height
          )

        assert_in_delta mean_of(square), mean(part), 3
      end

      {:ok, top_left} = Storehouse.variant(file, :square, opts(crop: {0, 0, 0.5, 0.5}))
      {:ok, bottom_right} = Storehouse.variant(file, :square, opts(crop: {0.5, 0.5, 0.5, 0.5}))
      assert top_left.key != bottom_right.key
    end

    test "smaller than the box: never enlarged, in the box's shape", %{original: file} do
      # 60 × 40 of the original, for a box of 100 × 100: its middle 40 × 40.
      {:ok, square} = Storehouse.variant(file, :square, opts(crop: {0, 0, 0.05, 0.05}))
      assert size(square) == {40, 40}
    end

    test "fitted, with a box of any height", %{original: file} do
      # The left half: 600 × 800, 320 wide.
      {:ok, thumb} = Storehouse.variant(file, :thumb, opts(crop: {0, 0, 0.5, 1}))
      assert size(thumb) == {320, 427}
    end

    test "of the original upright, as its EXIF turns it" do
      # 8 × 6, turned: 6 × 8 upright; its top half is 6 × 4.
      {:ok, turned} = Storehouse.store(Path.join(@fixtures, "turned.jpg"), adapter: Memory)

      {:ok, thumb} =
        Storehouse.variant(
          turned,
          :thumb,
          opts(presets: [thumb: [width: 6]], crop: {0, 0, 1, 0.5})
        )

      assert size(thumb) == {6, 4}
    end
  end
end
