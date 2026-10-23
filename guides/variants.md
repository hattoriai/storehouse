# Variants

A photograph's thumbnail, its sizes for a `srcset`, its WebP: a file's
variants, by preset. Storehouse keeps the set of sizes closed, gives each
variant a URL that never changes, and deletes the variants with their
original. What renders them is up to the app:

* **In the app**, with libvips (`Storehouse.Renderer.Vix`): each variant
  made the first time it is asked for, stored beside its original, and
  served by a plug. For an app without an image service.
* **Elsewhere**, with imgproxy behind a CDN (`Storehouse.Renderer.Imgproxy`),
  or a service of the app's own: Storehouse builds and signs the URLs, and
  renders nothing.

## Presets

Only a preset's sizes are ever rendered. A URL with any other size gives
`404`, so no one can make the server render at a size of their choosing.

```elixir
config :storehouse, Storehouse.Variants,
  presets: [
    thumb: [width: 320, height: 320, fit: :cover, focus: :attention],
    photo: [widths: [640, 960, 1280, 1920, 2560], format: [:webp, :original]],
    social: [width: 1200, aspect: {1200, 630}, fit: :cover, format: :jpeg, quality: 85]
  ]
```

A preset has a width, or a ladder of `:widths`, and optionally a box
(`:height`, or `:aspect` across a ladder) that the image fits inside
(`fit: :inside`, the default) or fills, cropped (`fit: :cover`). A crop
keeps the centre, what stands out (`:attention`), the busiest part
(`:entropy`), or a point (`{x, y}`, in fractions). A variant is never
larger than its original: a width past the original's gives the
original's.

Formats are `:original` (the default: the original's, or JPEG when
browsers do not show it), `:webp`, `:jpeg`, `:png`, `:avif` and `:gif`. A
list is chosen from by the browser's `Accept`: the first it takes, else
the last. `[:webp, :original]` gives WebP to the browsers that ask for it,
and the original's format to the rest. A variant is stored once per
format, so the cache key is the format, not the `Accept` header with its
hundreds of spellings.

By default a variant is in sRGB and carries none of the original's
metadata, so where a photograph was taken never reaches a page.
`profile: :keep` keeps a wide-gamut photograph's colour profile, and
`metadata: :all` keeps its EXIF. `Storehouse.Variants` lists every
option.

## In the app, with libvips

Add Vix. `Storehouse.Renderer.Vix` is then the renderer, and needs no
configuration:

```elixir
# mix.exs
{:vix, "~> 0.31"}
```

In the endpoint, before the router:

```elixir
plug Storehouse.Variants.Plug
```

Then, in a page:

```heex
<img src={Storehouse.variant_url(@photo.image, :thumb)} width="320" height="320" alt="" />

<img
  src={Storehouse.variant_url(@photo.image, :photo, width: 1280)}
  srcset={
    Enum.map_join([640, 960, 1280, 1920, 2560], ", ", fn width ->
      "#{Storehouse.variant_url(@photo.image, :photo, width: width)} #{width}w"
    end)
  }
  sizes="(min-width: 60rem) 60rem, 100vw"
  alt={@photo.caption}
/>
```

`Storehouse.variant_url/3` is the same every time, and costs nothing: it
reads no store. The first request for a variant makes it: the plug
downloads the original, renders it, stores the result under
`variants/<original key>/` and sends it. Every request after that is
served from the store. Each variant is sent with
`Cache-Control: public, max-age=31536000, immutable` (and `Vary: Accept`
for a preset of several formats), so a CDN in front keeps it for a year.

A URL carries a fingerprint of its preset. A preset you change gets new
URLs, so no CDN serves a variant of the old preset. A request for an old
fingerprint, from a page cached before the change, is redirected to the
current URL.

**Made once.** Fifty requests at once for a variant not yet made render it
once. The first caller starts a process registered under the variant's key
in `:global`, across every node of the cluster, and the other callers wait
for its result. A caller waits up to `:timeout` (60 seconds by default),
then gets `503`. To make a variant outside a request, before its first
visitor:

```elixir
{:ok, thumb} = Storehouse.variant(file, :thumb)
```

For example, in a job after an upload, for the sizes a page will ask for
first.

**Which originals.** The plug renders any image in the store whose key it
is given. Files that must stay private (served only at signed URLs) should
be kept out of it with `:only`, a list of key prefixes or a function:

```elixir
plug Storehouse.Variants.Plug, only: ["photos/", "avatars/"]
```

**Formats.** The precompiled libvips that Vix brings reads JPEG, PNG,
WebP, TIFF, GIF and AVIF, and writes all of them except AVIF. Build Vix
against the system's libvips for HEIC, or to write AVIF.

## imgproxy behind a CDN

An image-heavy app often renders outside the BEAM already. With
`Storehouse.Renderer.Imgproxy`, Storehouse builds imgproxy's URLs for the
presets, signed with imgproxy's key and salt, and the app renders and
stores nothing:

```elixir
config :storehouse, Storehouse.Variants,
  renderer:
    {Storehouse.Renderer.Imgproxy,
     url: "https://images.example.com",
     key: System.fetch_env!("IMGPROXY_KEY"),
     salt: System.fetch_env!("IMGPROXY_SALT"),
     source: "s3://my-bucket/"},
  presets: [
    photo: [widths: [640, 960, 1280, 1920, 2560, 3840], format: [:webp, :original]]
  ]
```

```elixir
Storehouse.variant_url(file, :photo, width: 1280)
#=> "https://images.example.com/<signature>/w:1280/czM6Ly9teS1idWNrZXQv…"
```

imgproxy reads the original from the bucket (`source:`), never enlarges
it, and strips its metadata. A CDN in front of imgproxy keeps each URL.
For a preset of several formats, Storehouse sets no format and imgproxy
chooses one from `Accept` (turn on `IMGPROXY_AUTO_WEBP` or
`IMGPROXY_AUTO_AVIF`).

A preset can carry imgproxy's own processing options as they are, which
are added after the ones Storehouse writes:

```elixir
photo: [
  widths: [640, 1280, 1920, 3840, 7680],
  profile: :keep,
  options: [imgproxy: "fq:webp:86:jpeg:90"]
]
#=> …/w:1280/scp:0/fq:webp:86:jpeg:90/<source>
```

Since the URLs are signed, a call may also give a photograph's own focus
point, which a URL for the plug cannot carry:

```elixir
Storehouse.variant_url(file, :social, focus: {photo.focus_x, photo.focus_y})
```

## A renderer of your own

A renderer is a module of `Storehouse.Renderer` that implements one or
both callbacks: `render/4` renders a variant from a file on the disk to
another, and `url/3` gives the URL of a variant another service renders.
The presets, the closed set of sizes and the fingerprints stay
Storehouse's.

For example, for URLs of another shape, such as a CDN's Worker that signs
short addresses itself:

```elixir
defmodule MyApp.ShortImages do
  @behaviour Storehouse.Renderer

  @impl true
  def url(variant, file, _opts),
    do: "https://images.example.com/p/#{file.key}/#{variant.width}"
end
```

`Storehouse.Renderer.Imgproxy.path/3` and `signed_path/2` build and sign
imgproxy's path, for a renderer that wraps it.

## Deleted with their original

Variants are stored under their original's key, so one prefix holds all
of them: `Storehouse.delete/2` of an original deletes them too, and
`Storehouse.delete_prefix/2` deletes those of every file under the
prefix. This happens when variants are configured with a renderer that
stores them, on a store that lists files (`Storehouse.Local`,
`Storehouse.S3`). Variants that imgproxy and a CDN keep are theirs to
expire.

## Telemetry

Each `Storehouse.variant/3` is a span, `[:storehouse, :variant, ...]`,
with the original's `:key`, the `:variant`'s key, the `:preset` and the
`:width`, and how it went (`result: :found | :made | :error`).
