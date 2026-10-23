if Code.ensure_loaded?(Vix.Vips.Operation) do
  defmodule Storehouse.Analyzer.BlurHash do
    @moduledoc """
    A step (`Storehouse.Analyzer`) that makes a photograph's
    [BlurHash](https://blurha.sh) (`Storehouse.Image.BlurHash`), under
    `"blurhash"`: a string of 20 to 30 characters, kept with the file, that
    a page decodes into a blur.

      * `"blurhash"` - the string.
      * `"color"` - its average colour, `#rrggbb`.
      * `"width"` and `"height"` - of the image it was made from: its
        proportions, to decode it at.

    ```elixir
    # mix.exs: libvips, through Vix.
    {:vix, "~> 0.31"}

    Storehouse.store(upload.path, analyze: [Storehouse.Analyzer.BlurHash])
    ```

    In the page, with `blurhash` from npm (or a component of it:
    `react-blurhash`, `vue-blurhash`):

    ```js
    import { decode } from "blurhash"
    const { blurhash, width, height } = file.analysis.blurhash
    const pixels = decode(blurhash, width, height)
    ```

    The shortest of the three placeholders, and the one most services
    know; `Storehouse.Analyzer.ThumbHash` is truer to colours and keeps
    transparency, `Storehouse.Analyzer.Placeholder` needs no script. Made
    as the image loads, never decoded whole; a file libvips does not read
    fails the step, with why. Not an image is skipped.

    ## Options

      * `:components` - `{x, y}`, 1 to 9 each: more is more detail, and a
        longer string. The default is `{4, 3}`.
      * `:size` - the longest edge it is made from, in pixels. The default
        is 32: the hash keeps little detail, and more pixels take longer.
      * `:background` - `"#rrggbb"`, under transparency, which a BlurHash
        does not keep. The default is white.
    """

    @behaviour Storehouse.Analyzer

    alias Storehouse.Analyzer.Pixels
    alias Storehouse.Image.BlurHash, as: Encoder
    alias Vix.Vips.Image

    @impl true
    def name, do: "blurhash"

    @impl true
    def analyze(%Storehouse.File{content_type: "image/" <> _}, path, opts) do
      {x, y} = Keyword.get(opts, :components, {4, 3})
      background = Pixels.background(Keyword.get(opts, :background, "#ffffff"))

      with {:ok, image} <- Pixels.small(path, Keyword.get(opts, :size, 32), background),
           {:ok, pixels} <- Pixels.rgb(image),
           {:ok, color} <- Pixels.color(image) do
        width = Image.width(image)
        height = Image.height(image)

        {:ok,
         %{
           "blurhash" => Encoder.encode(width, height, pixels, x, y),
           "color" => color,
           "width" => width,
           "height" => height
         }}
      end
    end

    def analyze(_file, _path, _opts), do: :skip
  end
end
