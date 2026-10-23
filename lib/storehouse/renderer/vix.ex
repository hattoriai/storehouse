if Code.ensure_loaded?(Vix.Vips.Operation) do
  defmodule Storehouse.Renderer.Vix do
    @moduledoc """
    Renders variants in the app, with libvips through Vix
    (`Storehouse.Renderer`): the default renderer when Vix is loaded.

        # mix.exs
        {:vix, "~> 0.31"}

    An image is shrunk as it is loaded, never decoded whole when it need
    not be: a 6000 × 4000 JPEG made 1280 wide is read at an eighth of its
    size. It is turned as its EXIF says, never enlarged, converted to sRGB
    (or its profile kept, with `profile: :keep`), and saved without its
    metadata unless the preset keeps it (`metadata: :all`). A crop to a
    point (`focus: {x, y}`) keeps that point as near the middle as the
    image allows.

    Which formats it reads and writes is libvips's: the precompiled one Vix
    brings reads JPEG, PNG, WebP, TIFF, GIF and AVIF, and writes all but
    AVIF; build Vix against the system's libvips for HEIC, or for AVIF.

    ## Options

      * `:quality` - for a preset that gives none. The default is 80.
      * `:max_pixels` - the largest original it renders, in pixels, read
        from its header before a pixel is decoded: a larger one gives
        `{:error, :too_large}`. The default is 200,000,000 (a 200 MP
        photograph). `Storehouse.Check`'s `:max_pixels` refuses most at
        upload; this one also holds for an image whose size the upload's
        first bytes did not say (a TIFF whose directory comes last).
    """

    @behaviour Storehouse.Renderer

    alias Vix.Vips.{Image, Operation}

    @interesting %{
      centre: :VIPS_INTERESTING_CENTRE,
      attention: :VIPS_INTERESTING_ATTENTION,
      entropy: :VIPS_INTERESTING_ENTROPY
    }
    # Any height: a box as tall as libvips takes.
    @any 10_000_000
    @max_pixels 200_000_000

    @impl true
    def render(source, destination, %Storehouse.Variant{} = variant, opts) do
      with :ok <- within(source, Keyword.get(opts, :max_pixels, @max_pixels)),
           {:ok, image} <- sized(source, variant),
           {:ok, image} <- coloured(image, variant),
           {:ok, image} <- flattened(image, variant) do
        Image.write_to_file(image, destination <> saved(variant, opts))
      end
    end

    defp sized(source, %{fit: :inside} = variant),
      do: thumbnail(source, variant.width, variant.height || @any, variant)

    defp sized(source, %{focus: {x, y}} = variant) do
      # Scaled to cover the box, then cut around the point.
      with {:ok, header} <- Image.new_from_file(source),
           {width, height} = upright(header),
           scale = min(1, max(variant.width / width, variant.height / height)),
           {:ok, image} <-
             thumbnail(source, ceil(width * scale), ceil(height * scale), variant) do
        cut = min(variant.width, Image.width(image))
        tall = min(variant.height, Image.height(image))
        left = clamp(round(x * Image.width(image) - cut / 2), Image.width(image) - cut)
        top = clamp(round(y * Image.height(image) - tall / 2), Image.height(image) - tall)
        Operation.extract_area(image, left, top, cut, tall)
      end
    end

    defp sized(source, variant) do
      thumbnail(source, variant.width, variant.height, variant,
        crop: Map.fetch!(@interesting, variant.focus)
      )
    end

    defp thumbnail(source, width, height, variant, extra \\ []) do
      profile = if variant.profile == :srgb, do: [export_profile: "srgb"], else: []

      Operation.thumbnail(
        source,
        width,
        [height: height, size: :VIPS_SIZE_DOWN] ++ profile ++ extra
      )
    end

    @doc false
    # No larger than max pixels, by its header: libvips reads that alone.
    def within(source, max) do
      case Image.new_from_file(source) do
        {:ok, image} ->
          if Image.width(image) * Image.height(image) > max, do: {:error, :too_large}, else: :ok

        {:error, _reason} = error ->
          error
      end
    end

    # Its size upright, as its EXIF turns it.
    defp upright(image) do
      case Image.header_value(image, "orientation") do
        {:ok, turned} when turned in 5..8 -> {Image.height(image), Image.width(image)}
        _upright -> {Image.width(image), Image.height(image)}
      end
    end

    defp clamp(value, most), do: value |> max(0) |> min(max(most, 0))

    # In sRGB, eight bits a band, unless its profile is kept.
    defp coloured(image, %{profile: :keep}), do: eight_bits(image)

    defp coloured(image, _variant) do
      with {:ok, image} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
           do: eight_bits(image)
    end

    defp eight_bits(image) do
      if Image.format(image) == :VIPS_FORMAT_UCHAR,
        do: {:ok, image},
        else: Operation.cast(image, :VIPS_FORMAT_UCHAR, shift: true)
    end

    # Transparency laid on the background, where the format has none.
    defp flattened(image, %{format: :jpeg} = variant) do
      if Image.has_alpha?(image),
        do: Operation.flatten(image, background: rgb(variant.background || "#ffffff")),
        else: {:ok, image}
    end

    defp flattened(image, _variant), do: {:ok, image}

    defp rgb(<<"#", hex::binary-6>>) do
      <<r, g, b>> = Base.decode16!(hex, case: :mixed)
      [r, g, b]
    end

    defp saved(variant, opts) do
      quality = variant.quality || Keyword.get(opts, :quality, 80)

      kept =
        case {variant.metadata, variant.profile} do
          {:all, _profile} -> []
          {:none, :keep} -> ["keep=icc"]
          {:none, :srgb} -> ["strip"]
        end

      options = if variant.format in [:png, :gif], do: kept, else: ["Q=#{quality}" | kept]
      if options == [], do: "", else: "[" <> Enum.join(options, ",") <> "]"
    end
  end
end
