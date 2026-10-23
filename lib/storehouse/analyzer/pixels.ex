if Code.ensure_loaded?(Vix.Vips.Operation) do
  defmodule Storehouse.Analyzer.Pixels do
    @moduledoc false
    # A photograph made small for a placeholder, with libvips: shrunk as it
    # loads, never decoded whole, turned as its EXIF says, in sRGB, eight
    # bits a band, transparency laid on a background when one is given.

    alias Storehouse.Renderer.Vix, as: Renderer
    alias Vix.Vips.{Image, Operation}

    @doc false
    def small(path, size, background) do
      with :ok <- Renderer.within(path, 200_000_000),
           {:ok, image} <- Operation.thumbnail(path, size, height: size),
           {:ok, image} <- Image.copy_memory(image),
           {:ok, image} <- srgb(image),
           do: flattened(image, background)
    end

    @doc false
    # Its pixels, row by row, RGBA or RGB.
    def rgba(image) do
      with {:ok, image} <- if(Image.has_alpha?(image), do: {:ok, image}, else: opaque(image)),
           do: Image.write_to_binary(image)
    end

    def rgb(image) do
      with {:ok, image} <- flattened(image, [255, 255, 255]),
           do: Image.write_to_binary(image)
    end

    @doc false
    # The average of its pixels' colour, each counted as much as it is
    # opaque, as `#rrggbb`.
    def color(image) do
      with {:ok, pixels} <- rgba(image), do: {:ok, hex(average(pixels))}
    end

    @doc false
    def background(nil), do: nil

    def background(<<"#", hex::binary-6>>) do
      <<r, g, b>> = Base.decode16!(hex, case: :mixed)
      [r, g, b]
    end

    def background(other),
      do: raise(ArgumentError, ":background is \"#rrggbb\", not #{inspect(other)}")

    # In sRGB, eight bits a band: greyscale, CMYK, 16-bit originals too.
    defp srgb(image) do
      with {:ok, image} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB) do
        if Image.format(image) == :VIPS_FORMAT_UCHAR,
          do: {:ok, image},
          else: Operation.cast(image, :VIPS_FORMAT_UCHAR, shift: true)
      end
    end

    defp flattened(image, nil), do: {:ok, image}

    defp flattened(image, background) do
      if Image.has_alpha?(image),
        do: Operation.flatten(image, background: background),
        else: {:ok, image}
    end

    defp opaque(image), do: Operation.bandjoin_const(image, [255.0])

    defp average(pixels) do
      {r, g, b, a} =
        for <<r, g, b, a <- pixels>>, reduce: {0, 0, 0, 0} do
          {sr, sg, sb, sa} -> {sr + r * a, sg + g * a, sb + b * a, sa + a}
        end

      if a == 0, do: [0, 0, 0], else: [div(r, a), div(g, a), div(b, a)]
    end

    defp hex(rgb),
      do:
        "#" <>
          Enum.map_join(
            rgb,
            &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
          )
  end
end
