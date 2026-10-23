if Code.ensure_loaded?(Vix.Vips.Operation) do
  defmodule Storehouse.Analyzer.Placeholder do
    @moduledoc ~S"""
    A step (`Storehouse.Analyzer`) that makes what a page shows while a
    photograph loads, under `"placeholder"`:

      * `"placeholder"` - a tiny version of it, a few hundred bytes, as a
        data URI the browser stretches into a soft blur: a `<img>`'s
        background, or React's `placeholder`.
      * `"color"` - its average colour, `#rrggbb`, painted under it.
      * `"width"` and `"height"` - the tiny version's, its proportions.

    ```elixir
    # mix.exs: libvips, through Vix.
    {:vix, "~> 0.31"}

    Storehouse.store(upload.path, analyze: [Storehouse.Analyzer.Placeholder])
    ```

    It is made with libvips, shrinking as it loads: a 6000 × 4000 JPEG is
    decoded at an eighth of its size or less, never whole, in about 150 ms
    where decoding it whole takes 260, and a few kilobytes past what the
    decoder holds. It is turned as
    its EXIF says, in sRGB. A file libvips does not read (one that is not
    an image; HEIC, where libvips is built without its codec) is skipped,
    or fails the step, with why: the photograph still shows, on its page's
    ground.

    ## Options

      * `:size` - the longest edge, in pixels. The default is 16: larger is
        sharper, and heavier.
      * `:format` - `:webp` (the default), `:jpeg` or `:png`.
      * `:quality` - 1 to 100, for WebP and JPEG. The default is 40.
      * `:background` - `"#rrggbb"`: a photograph with transparency is laid
        on it, and its colour taken so. The default keeps its transparency
        (in WebP and PNG; JPEG has none, and is laid on white).

    ## In a page

    ```heex
    <img src={@photo.url} width={@photo.width} height={@photo.height}
         style={"background: #{analyzed.color} url(#{analyzed.placeholder}) center / cover"} />
    ```

    and in JSON, for a React `<img>` (`Storehouse.File.to_map(file,
    analysis: [:placeholder])`).

    For a frontend that decodes a hash instead, `Storehouse.Analyzer.ThumbHash`
    and `Storehouse.Analyzer.BlurHash`.
    """

    @behaviour Storehouse.Analyzer

    alias Storehouse.Analyzer.Pixels
    alias Vix.Vips.Image

    @formats %{
      webp: {".webp", "image/webp"},
      jpeg: {".jpg", "image/jpeg"},
      png: {".png", "image/png"}
    }

    @impl true
    def name, do: "placeholder"

    @impl true
    def analyze(%Storehouse.File{content_type: type}, path, opts) do
      if String.starts_with?(type, "image/"), do: placeholder(path, opts), else: :skip
    end

    defp placeholder(path, opts) do
      size = Keyword.get(opts, :size, 16)
      format = Keyword.get(opts, :format, :webp)
      {suffix, mime} = Map.fetch!(@formats, format)
      background = Keyword.get(opts, :background, if(format == :jpeg, do: "#ffffff"))

      with {:ok, image} <- Pixels.small(path, size, Pixels.background(background)),
           {:ok, encoded} <- Image.write_to_buffer(image, "#{suffix}#{saved(format, opts)}"),
           {:ok, color} <- Pixels.color(image) do
        {:ok,
         %{
           "placeholder" => "data:#{mime};base64," <> Base.encode64(encoded),
           "color" => color,
           "width" => Image.width(image),
           "height" => Image.height(image)
         }}
      end
    end

    # No metadata: none of the original's EXIF (where it was taken), ICC
    # profile or XMP goes into a page.
    defp saved(:png, _opts), do: "[strip]"
    defp saved(_format, opts), do: "[Q=#{Keyword.get(opts, :quality, 40)},strip]"
  end
end
