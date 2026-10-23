defmodule Storehouse.Renderer do
  @moduledoc """
  What makes a file's variants (`Storehouse.Variants`), or the URLs of
  the service that makes them. A renderer does one or both:

    * `c:render/4` - renders a variant in the app, from the original on
      the disk, to a file: `Storehouse.Variants` downloads the original,
      stores the result under the original's key, once however many ask
      for it, and `Storehouse.Variants.Plug` serves it.
      `Storehouse.Renderer.Vix` (libvips) is one.
    * `c:url/3` - the URL of a variant another service renders (imgproxy,
      thumbor, Cloudflare Images), behind a CDN: the app renders nothing.
      `Storehouse.Renderer.Imgproxy` is one.

  A renderer with `c:url/3` gives every variant's URL; one with only
  `c:render/4` has `Storehouse.Variants.Plug`'s. Either way, only the
  presets' sizes are ever asked for.

  Configured as a module, or `{module, options}`; the options are given to
  each callback:

      config :storehouse, Storehouse.Variants,
        renderer: {Storehouse.Renderer.Imgproxy, url: "https://images.example.com", ...}

  A renderer of the app's own (another service's URLs, URLs of its own
  shape) implements either callback.
  """

  @doc """
  Renders `variant` from the original at `source` to `destination`, a path
  with the format's extension. Never larger than the original.
  """
  @callback render(
              source :: Path.t(),
              destination :: Path.t(),
              Storehouse.Variant.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc """
  The URL of `variant`. Its `:format` is a list when the format is to be
  chosen from the browser's `Accept`, by the service.
  """
  @callback url(Storehouse.Variant.t(), Storehouse.File.t(), opts :: keyword()) :: String.t()

  @optional_callbacks render: 4, url: 3
end
