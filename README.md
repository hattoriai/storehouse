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
> uploads streamed through the app with no temporary file, files in
> Ecto records (temporary until saved, permanent then), signed URLs for
> private files, checksums, telemetry, files from an address, reading
> files back, and LiveView uploads are here. Before 1.0,
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

Storehouse needs Elixir 1.17 or later (with Jason in your deps before
1.18, which has its own `JSON`) and, for `Storehouse.Live`,
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
* **uploads streamed through your app** with no file on its disk: to S3
  in the parts of a multipart upload as the chunks come, checked by their
  first bytes on the way, two parts in flight from a process of their
  own, the upload held back when the bucket is slower than the browser;
* **files in Ecto records**: a column of the file (`Storehouse.Ecto.File`),
  no table of files; an upload is temporary until its record is saved,
  made permanent then by a copy in the store, and a bucket's lifecycle
  rule deletes those of forms never saved; files replaced or removed are
  deleted once the database has the change;
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
* **cleanup**: files listed and deleted by prefix (an account's, a
  thousand at a time on S3), deletions tried again until the store
  answers, and temporary files of forms never saved swept, by
  `Storehouse.Cleaner`, a process of your app's, with no cron;
* **files read back**: a file's size and type without reading it, its
  bytes all at once, as a stream a chunk at a time, or to a path, each
  refused past a size limit before a byte is read;
* **work after the upload**: steps of your own (an image's EXIF, a PDF's
  pages) run on a stored file, at once or out of the request, in a
  process of your app's or in Oban, their results kept in its metadata
  and saved in its record's column;
* **what happens to files, as it happens**: a file stored, its analysis
  done or failed, a file deleted, told to a function of yours or
  broadcast on your app's PubSub, on a topic you choose (an account's);
* **metadata of your own** on each file (a caption, a credit), kept in
  its column and sent in its JSON, apart from what analysis reads from
  the file, which stays out of the JSON unless you ask for it;
* **limits**: the largest file, the most pixels of an image, the types
  you take;
* **checksums**: each file's SHA-256, kept with it, and checked by S3 as
  it takes the file;
* **tests that need no store**: `Storehouse.Memory`, in memory, each
  test's files its own under `async: true`, with assertions
  (`Storehouse.Test`) and failures on demand;
* **telemetry**: `:telemetry` spans for storing, fetching, signing,
  checking, reading and deleting, with what was refused and why;
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

In a record:

```elixir
schema "users" do
  field :avatar, Storehouse.Ecto.File
end

user
|> User.changeset(attrs)
|> Storehouse.Ecto.put_file(:avatar, avatar, accept: Storehouse.Check.images(), max_bytes: 5_000_000)
|> then(&Storehouse.Ecto.update(Repo, &1))
```

The guides: [Stores](guides/stores.md) (the local disk, S3, LocalStack,
development), [Direct uploads](guides/direct_uploads.md) (and streamed
ones), [Ecto](guides/ecto.md), [Private files](guides/private_files.md),
[Serving](guides/serving.md), [LiveView](guides/liveview.md) and
[After the upload](guides/analysis.md).

## How Storehouse compares

The Elixir libraries that keep an app's files, as their documentation
and code describe them in October 2026. This table follows Storehouse's
releases: each change to one of its rows updates it. A correction about
another library is welcome as an issue.

| | Storehouse | [Waffle](https://hex.pm/packages/waffle) 2.0 | [Capsule](https://hex.pm/packages/capsule) 1.0 | [phx_media_library](https://hex.pm/packages/phx_media_library) 0.10 | [attached](https://hex.pm/packages/attached) 0.2 |
|---|---|---|---|---|---|
| A file's type from its bytes, a safe key | Yes | From its extension | No | Partly | Partly |
| Serving with safe headers (`nosniff`, a sandboxing CSP, ranges) | Yes | — | — | — | — |
| Uploads straight to the store | Yes, checked by their first bytes | No | No | Yes | Presigned only |
| Uploads streamed through the app, no temporary file | Yes | No | No | No | No |
| Temporary until saved, then permanent | Yes | No | By hand | Partly | No |
| Checksums, checked by the store | Yes | No | No | Yes | Yes |
| Files from an address | Yes, from allowed hosts only | Yes, size-capped | No | No | No |
| LiveView uploads | Yes | No | No | Partly | No |
| Reading a file back | Yes | Yes | Yes | Yes | Yes |
| A file's own metadata | Yes, kept apart from the analysis's | No | Yes | Yes | Yes, shared with the analysis's |
| Several stores at once | Not yet ([#1](https://github.com/hattoriai/storehouse/issues/1)) | Per uploader | Per file | Yes | One at a time |
| Work after the upload, analysis | Yes: steps of your own, in a process of your app's or in Oban | No | No | Yes | Yes, on Oban |
| Variants | Not yet ([#6](https://github.com/hattoriai/storehouse/issues/6)) | Made at upload | No | Yes | On demand |
| Placeholders while an image loads | Not yet ([#4](https://github.com/hattoriai/storehouse/issues/4)) | No | No | Yes | No |
| A table of files | Not yet ([#16](https://github.com/hattoriai/storehouse/issues/16)) | No | No | Yes | Yes |
| The same file uploaded again is the one kept | Not yet ([#15](https://github.com/hattoriai/storehouse/issues/15)) | No | No | No | No |
| Endpoints and a client for frontends without LiveView | Not yet ([#10](https://github.com/hattoriai/storehouse/issues/10), [#11](https://github.com/hattoriai/storehouse/issues/11)) | No | No | Presign and complete | No |
| Resumable and multipart uploads from the browser | Not yet ([#12](https://github.com/hattoriai/storehouse/issues/12)) | No | No | No | No |
| A store in memory, for async tests | Yes, with assertions | No | Yes | Yes | No |
| Dependencies | None | Req, ImageMagick | None | Several | Oban, Vix |

## Roadmap

* **Variants**: images resized and converted on demand, and cached, each
  made once however many ask for it at the same time, across a cluster.
* **Previews and analysis**: a PDF's first page, a video's poster, its
  length and size, audio; metadata of the app's own, read again later.
* **Cleanup of unused files**: the files no record uses any more, found
  by comparing the app's records with the store.
* **Resumable uploads** that survive a reconnect (and the tus protocol),
  and multipart uploads straight from the browser, for very large files.
* **Endpoints for other clients**: presign and upload endpoints, for Uppy
  and for apps with no LiveView.
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
