if Code.ensure_loaded?(Vix.Vips.Operation) do
  defmodule Storehouse.Analyzer.ThumbHash do
    @moduledoc """
    A step (`Storehouse.Analyzer`) that makes a photograph's
    [ThumbHash](https://evanw.github.io/thumbhash/) (`Storehouse.ThumbHash`),
    under `"thumbhash"`: about 25 bytes, kept with the file, that a page
    decodes into a blur of its colours, proportions and transparency.

      * `"thumbhash"` - its bytes, in Base64.
      * `"color"` - its average colour, `#rrggbb`.
      * `"width"` and `"height"` - of the image it was made from, at most
        100 each: its proportions.

    ```elixir
    # mix.exs: libvips, through Vix.
    {:vix, "~> 0.31"}

    Storehouse.store(upload.path, analyze: [Storehouse.Analyzer.ThumbHash])
    ```

    In the page, with `thumbhash` from npm:

    ```js
    import { thumbHashToDataURL } from "thumbhash"
    const bytes = Uint8Array.from(atob(file.analysis.thumbhash.thumbhash), (c) => c.charCodeAt(0))
    img.style.background = `center / cover url(${thumbHashToDataURL(bytes)})`
    ```

    Smaller than `Storehouse.Analyzer.Placeholder`'s image, which needs no
    script to show; larger than `Storehouse.Analyzer.BlurHash`'s string,
    and truer to the photograph's colours, with its transparency. Made as
    the image loads, at most 100 pixels a side, never decoded whole; a file
    libvips does not read fails the step, with why. Not an image is
    skipped.

    ## Options

      * `:background` - `"#rrggbb"`: transparency laid on it, and kept out
        of the hash. The default keeps it.
    """

    @behaviour Storehouse.Analyzer

    alias Storehouse.Analyzer.Pixels
    alias Vix.Vips.Image

    @impl true
    def name, do: "thumbhash"

    @impl true
    def analyze(%Storehouse.File{content_type: "image/" <> _}, path, opts) do
      background = Pixels.background(Keyword.get(opts, :background))

      with {:ok, image} <- Pixels.small(path, 100, background),
           {:ok, pixels} <- Pixels.rgba(image),
           {:ok, color} <- Pixels.color(image) do
        width = Image.width(image)
        height = Image.height(image)

        {:ok,
         %{
           "thumbhash" => Base.encode64(Storehouse.ThumbHash.encode(width, height, pixels)),
           "color" => color,
           "width" => width,
           "height" => height
         }}
      end
    end

    def analyze(_file, _path, _opts), do: :skip
  end
end
