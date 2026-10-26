# Storehouse

![Storehouse — Files for Phoenix](https://raw.githubusercontent.com/hattoriai/storehouse/main/media/banner.png)

<p>
  <a href="https://hex.pm/packages/storehouse">
    <img alt="Hex Version" src="https://img.shields.io/hexpm/v/storehouse.svg">
  </a>
  <a href="https://hexdocs.pm/storehouse">
    <img src="https://img.shields.io/badge/docs-hexdocs-blue" alt="HexDocs">
  </a>
  <a href="https://github.com/hattoriai/storehouse/actions">
    <img alt="CI Status" src="https://github.com/hattoriai/storehouse/actions/workflows/ci.yml/badge.svg">
  </a>
</p>

**Files for Phoenix: uploads checked by their bytes, stored under safe
keys, and served safely.**

Photos people upload, a document's attachments, the exports your app
makes. Storehouse checks each file by its contents, not its name, stores
it on the local disk or in S3 (or R2, MinIO, Tigris), and serves it so it
can never run a script on your app's origin.

> Early release. Before 1.0, a minor version may change the API.

## Install

You need Elixir 1.17+. `Storehouse.Live` also needs Phoenix LiveView
1.1+; the rest works in any Plug app.

Add Storehouse to the deps in `mix.exs`:

```elixir
{:storehouse, "~> 0.3"}
```

On Elixir 1.17, add `{:jason, "~> 1.4"}` too. 1.18 and later have their
own `JSON`.

## Your first file

Tell Storehouse where to keep files, and serve them from your endpoint:

```elixir
# config/runtime.exs
config :storehouse, Storehouse.Local, root: "/var/lib/my_app/uploads"

# lib/my_app_web/endpoint.ex, before the router
plug Storehouse.Local.Plug
```

Store a file:

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

Keep it in a record:

```elixir
schema "users" do
  field :avatar, Storehouse.Ecto.File
end

user
|> User.changeset(attrs)
|> Storehouse.Ecto.put_file(:avatar, upload, accept: Storehouse.Check.images(), max_bytes: 5_000_000)
|> then(&Storehouse.Ecto.update(Repo, &1))
```

A list field (`{:array, Storehouse.Ecto.File}`) holds many, with
`add_files/4` and `remove_file/3`. The [Ecto](guides/ecto.md) guide has
both, and how each Active Storage call maps to Storehouse.

Or store the files of a LiveView upload:

```elixir
{socket, results} = Storehouse.Live.consume(socket, :photos, accept: Storehouse.Check.images())
```

The [Stores](guides/stores.md) guide sets up S3, development and tests.

## What you get

* **Files checked by their bytes.** Images, camera photos (HEIC, AVIF,
  DNG), PDF, video, ZIP and Office files. An HTML page renamed `.png` is
  refused or sent as a download. → [Serving](guides/serving.md)
* **Your choice of store.** The local disk, S3 and the stores that speak
  its API, or your own. Several at once, and files copied between them.
  → [Stores](guides/stores.md)
* **Uploads straight to the bucket.** Signed in your app, checked when
  they land. Very large files go in parts and resume after a reload.
  → [Direct uploads](guides/direct_uploads.md)
* **Files in Ecto records.** A column, no join table. Temporary until
  the record is saved, deleted once it no longer has them.
  → [Ecto](guides/ecto.md)
* **Private files.** Signed URLs that expire, or files streamed through
  your app after it checks the person. → [Private files](guides/private_files.md)
* **Variants and placeholders.** Thumbnails and `srcset` sizes with
  libvips or imgproxy, and a tiny preview while a photo loads.
  → [Variants](guides/variants.md), [After the upload](guides/analysis.md)
* **Any frontend.** JSON endpoints and a JavaScript client for React,
  Vue or a native app, and tus for Uppy and mobile clients.
  → [Uploads from any client](guides/any_client.md)
* **Work in the background.** Analysis, deletions and mirrors run on
  Oban, or on a process of your app's. → [Work out of the request](guides/background.md)
* **Tests without a store.** An in-memory store, safe under
  `async: true`, with assertions. → [Stores](guides/stores.md#in-tests)

The full list is in [Features](guides/features.md).

## Guides

[Stores](guides/stores.md) ·
[Serving](guides/serving.md) ·
[LiveView](guides/liveview.md) ·
[Direct uploads](guides/direct_uploads.md) ·
[Uploads from any client](guides/any_client.md) ·
[Private files](guides/private_files.md) ·
[Ecto](guides/ecto.md) ·
[After the upload](guides/analysis.md) ·
[Variants](guides/variants.md) ·
[Work out of the request](guides/background.md) ·
[Features](guides/features.md)

## How Storehouse compares

The Elixir libraries that keep an app's files, as their documentation and
code describe them in October 2026. A correction is welcome as an issue.

| | Storehouse 0.2 | [Waffle](https://hex.pm/packages/waffle) 2.0 | [Capsule](https://hex.pm/packages/capsule) 1.0 | [phx_media_library](https://hex.pm/packages/phx_media_library) 0.10 | [attached](https://hex.pm/packages/attached) 0.2 |
|---|---|---|---|---|---|
| Type checked from the bytes | Yes | No (extension) | No | Partly | Partly |
| Safe serving headers | Yes | No | No | No | No |
| CDN cache headers and purges | Yes | No | No | Partly | No |
| Private files through the app | Yes | No | No | Yes | No |
| Uploads straight to the store | Yes | No | No | Yes | Partly |
| Streamed uploads, no temporary file | Yes | No | No | No | No |
| Temporary until saved | Yes | No | Partly | Partly | No |
| Checksums | Yes | No | No | Yes | Yes |
| Files from a URL | Yes | Yes | No | No | No |
| LiveView uploads | Yes | No | No | Partly | No |
| Reading files back | Yes | Yes | Yes | Yes | Yes |
| Your own metadata | Yes | No | Yes | Yes | Yes |
| Photo metadata edited without re-encoding | Yes | No | No | No | No |
| Several stores at once | Yes | Per uploader | Per file | Yes | No |
| Background processing | Yes | No | No | Yes | Yes |
| Variants | Yes | At upload | No | Yes | On demand |
| Placeholders | Yes | No | No | Yes | No |
| A table of files | Optional | No | No | Yes | Yes |
| Duplicate uploads detected | Yes | No | No | No | No |
| JavaScript client, non-LiveView endpoints | Yes | No | No | Partly | No |
| Resumable and multipart uploads | Yes | No | No | No | No |
| In-memory store for tests | Yes | No | Yes | Yes | No |
| Dependencies | Plug, Req, Telemetry | Req, ImageMagick | None | Several | Oban, Vix |

## Roadmap

* A PDF's first page and a video's poster as previews; video and audio
  length.
* Finding files no record uses any more.
* Azure and native Google Cloud Storage. Google Cloud Storage works
  through its S3 API today.

## Development

```sh
mix deps.get
mix test
mix credo --strict
mix dialyzer
node --test test/js/*.test.mjs
```

## License

MIT. See [LICENSE](https://github.com/hattoriai/storehouse/blob/main/LICENSE).
