defmodule Storehouse.Variant do
  @moduledoc """
  One size of a file, in one format, as a preset makes it: what a renderer
  (`Storehouse.Renderer`) is given to render it, or to build its URL.

    * `:source` - the original's key.
    * `:preset` - the preset's name, an atom.
    * `:width` - one of the preset's widths.
    * `:height` - the height of the box, or `nil` for any height.
    * `:fit` - `:inside` (scaled to fit the box, its proportions kept) or
      `:cover` (cropped to fill it).
    * `:focus` - what a crop keeps: `:centre`, `:attention` (what stands
      out), `:entropy` (the busiest part), or `{x, y}`, a point in
      fractions of the width and height from the top left.
    * `:format` - `:webp`, `:jpeg`, `:png`, `:avif`, `:gif`. For a URL,
      the preset's: `:original` among them, and a list, in order, when the
      format is chosen from the browser's `Accept`.
    * `:quality` - 1 to 100, or `nil` for the renderer's own.
    * `:profile` - `:srgb` (converted to sRGB) or `:keep` (its colour
      profile kept, for wide-gamut photographs).
    * `:metadata` - `:none` (none of the original's EXIF, IPTC or XMP)
      or `:all`.
    * `:background` - `"#rrggbb"`, under transparency a format without it
      (JPEG) cannot keep.
    * `:options` - the preset's options for a renderer of its own, by
      renderer: `imgproxy: "fq:webp:86"`.
    * `:fingerprint` - eight hex digits of all of the above that change
      the image: a preset changed is a new URL, and a new key.
  """

  @enforce_keys [:source, :preset, :width, :format, :fingerprint]
  defstruct [
    :source,
    :preset,
    :width,
    :height,
    :format,
    :quality,
    :fingerprint,
    :background,
    fit: :inside,
    focus: :centre,
    profile: :srgb,
    metadata: :none,
    options: []
  ]

  @type format :: :webp | :jpeg | :png | :avif | :gif
  @type t :: %__MODULE__{
          source: String.t(),
          preset: atom(),
          width: pos_integer(),
          height: pos_integer() | nil,
          fit: :inside | :cover,
          focus: :centre | :attention | :entropy | {number(), number()},
          format: format() | :original | [format() | :original],
          quality: 1..100 | nil,
          profile: :srgb | :keep,
          metadata: :none | :all,
          background: String.t() | nil,
          options: keyword(),
          fingerprint: String.t()
        }

  @extensions %{webp: "webp", jpeg: "jpg", png: "png", avif: "avif", gif: "gif"}
  @content_types %{
    webp: "image/webp",
    jpeg: "image/jpeg",
    png: "image/png",
    avif: "image/avif",
    gif: "image/gif"
  }

  @doc "A format's file extension, without the dot."
  @spec extension(format()) :: String.t()
  def extension(format), do: Map.fetch!(@extensions, format)

  @doc "A format's content type."
  @spec content_type(format()) :: String.t()
  def content_type(format), do: Map.fetch!(@content_types, format)
end
