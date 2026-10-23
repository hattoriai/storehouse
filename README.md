# Storehouse

![Storehouse — Files for Phoenix](https://raw.githubusercontent.com/hattoriai/storehouse/main/media/banner.png)

Storehouse keeps the files of a Phoenix app: the photos people upload,
the attachments of a document, the images on a canvas, the files an app
makes itself. Each file is checked by its bytes, stored under a new, safe
key, in a store of your choosing, and served so that it can never run a
script on your app's origin.

It is the storage of the Hattori libraries, taken out of them: Kotoba's
attachments and Hakushi's images keep their files with it, and so can
your app.

> **Status: early release.** Checking, storing, the local disk and S3
> (and the stores that speak its API), uploads straight to the store,
> signed URLs for private files, checksums, telemetry, files from an
> address, and LiveView uploads are here. Before 1.0,
> a minor version may change the API; see the roadmap for what comes
> next.

## Installation

```elixir
def deps do
  [
    {:storehouse, "~> 0.1"}
  ]
end
```

Storehouse needs Elixir 1.18 or later and, for `Storehouse.Live`,
Phoenix LiveView 1.1 or later. The rest works in any Plug app.

It gives your app:

* **files checked by their bytes**, not their names: PNG, JPEG, GIF and
  WebP images (with their width and height, a phone's photo turned as
  its EXIF says), PDF, MP4 and WebM video, ZIP and Office documents, and
  plain text. Anything else (HTML, SVG, JavaScript, a page renamed
  `.png`) is `application/octet-stream`, a download, or refused;
* **safe keys**: `yyyy/mm/<uuid>-<safe name><extension>`, whose
  extension comes from the checked type, so a key never ends in `.html`;
  an adapter refuses any key that could leave its root;
* **stores**: the local disk, and S3 with the stores that speak its API
  (Cloudflare R2, MinIO, Tigris, LocalStack), with no other library; or
  one of your own, in three callbacks;
* **uploads straight to the store**: the browser sends a file to the
  bucket at a URL your app signed (its type, its size, ten minutes), so a
  large file never goes through your app, and Storehouse checks it there
  by its first bytes; in development, to your app's own plug, the same
  way;
* **private files**: signed URLs that expire, from S3 or the local plug,
  and `Storehouse.Redirect`, a lasting URL of your app that checks the
  person and redirects to a fresh one;
* **serving that is safe**: `Storehouse.Local.Plug` sends the checked
  type, `nosniff`, a sandboxing CSP, downloads for every type a browser
  should not show, and byte ranges, for video;
* **LiveView uploads, stored**: `Storehouse.Live.consume/3` stores each
  finished entry once, cancels those the upload refused, and gives you a
  result for each;
* **files from an address**, from the hosts you allow only, with
  redirects checked and the download stopped at the size limit: an image
  pasted by its address, a file an agent names;
* **limits**: the largest file, the most pixels of an image, the types
  you take;
* **checksums**: each file's SHA-256, kept with it, and checked by S3 as
  it takes the file;
* **telemetry**: `:telemetry` spans for storing, fetching, signing,
  checking and deleting, with what was refused and why;
* **previews**: a function of yours gives a smaller image of a file (a
  thumbnail, a PDF's first page), kept with it.

## A sketch

```elixir
# config/runtime.exs
config :storehouse, Storehouse.Local, root: "/var/lib/my_app/uploads"

# lib/my_app_web/endpoint.ex, before the router
plug Storehouse.Local.Plug
```

```elixir
{:ok, file} = Storehouse.store("priv/seeds/palette.png")

file
#=> %Storehouse.File{
#     key: "2026/10/0b6…-palette.png",
#     url: "/uploads/2026/10/0b6…-palette.png",
#     name: "palette.png",
#     content_type: "image/png",
#     bytes: 48_211,
#     width: 1600,
#     height: 1000,
#     preview: nil
#   }
```

In a LiveView:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:photos, [])
   |> allow_upload(:photos,
     accept: ~w(.png .jpg .jpeg .gif .webp),
     max_file_size: 10_000_000,
     auto_upload: true,
     progress: &handle_progress/3
   )}
end

defp handle_progress(:photos, _entry, socket) do
  {socket, results} = Storehouse.Live.consume(socket, :photos, accept: Storehouse.Check.images())

  {:noreply,
   Enum.reduce(results, socket, fn
     {_entry, {:ok, file}}, socket -> update(socket, :photos, &[file | &1])
     {entry, {:error, reason}}, socket -> put_flash(socket, :error, "#{entry.client_name}: #{inspect(reason)}")
   end)}
end
```

From an address:

```elixir
Storehouse.fetch("https://images.example.com/board.png",
  hosts: ["images.example.com"],
  accept: Storehouse.Check.images(),
  max_bytes: 10_000_000
)
```

Straight to the store, with S3 in production and the local disk (or
LocalStack) in development:

```elixir
socket
|> Storehouse.Live.allow(:photos, accept: ~w(.png .jpg .jpeg), max_file_size: 50_000_000, auto_upload: true, progress: &handle_progress/3)
```

```javascript
import {Uploaders} from "storehouse"
let liveSocket = new LiveSocket("/live", Socket, {uploaders: Uploaders, params: {_csrf_token: csrfToken}})
```

A private file:

```elixir
{:ok, url} = Storehouse.signed_url(file.key, expires_in: 300)
```

The guides: [Stores](guides/stores.md) (the local disk, S3, LocalStack,
development), [Direct uploads](guides/direct_uploads.md),
[Private files](guides/private_files.md), [Serving](guides/serving.md)
and [LiveView](guides/liveview.md).

## Roadmap

* **Cleanup of unused files**: deleted files stay in storage today, and
  abandoned direct uploads too.
* **Variants**: images resized and converted on demand and cached. Today
  the app passes a preview function.
* **Previews and analysis**: a PDF's first page, a video's poster, length
  and audio. Storehouse reads image sizes only.
* **Mirror**: writing to two stores at once, for migrating between them.
* **Proxy mode**: streaming private bucket files through the app, for a
  CDN in front.
* **Azure and native Google Cloud Storage**: Google Cloud Storage works
  through its S3-compatible API today.

## Development

```sh
mix deps.get
mix test
mix credo --strict
mix dialyzer
```

## License

MIT. See [LICENSE](https://github.com/hattoriai/storehouse/blob/main/LICENSE).
