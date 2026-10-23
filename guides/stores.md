# Stores

A store keeps the files: `Storehouse.Local` (the local disk, the
default), `Storehouse.S3` (S3 and the stores that speak its API), or an
adapter of your own (`Storehouse.Adapter`).

## The local disk

```elixir
# config/config.exs
config :storehouse, adapter: Storehouse.Local

# config/runtime.exs
if config_env() == :prod do
  config :storehouse, Storehouse.Local,
    root: System.get_env("UPLOADS", "/var/lib/my_app/uploads"),
    url_prefix: "/uploads"
end

# config/dev.exs
config :storehouse, Storehouse.Local, root: Path.expand("../tmp/uploads", __DIR__)
```

In a release, give an absolute `root` outside the release directory, in
the `:prod` block of `config/runtime.exs`. A relative path is relative to
the working directory, and files in the release directory are lost at the
next deploy. Keep the production root inside the `:prod` block:
`config/runtime.exs` runs in every environment, after `config/dev.exs`,
so outside the block it would replace the development root.

Serve the files with `Storehouse.Local.Plug` (see [Serving](serving.md)).

## S3, and the stores that speak its API

`Storehouse.S3` keeps the files in a bucket of Amazon S3, or of a store
with its API: Cloudflare R2, MinIO, Tigris, Backblaze B2, DigitalOcean
Spaces, Google Cloud Storage's interoperability. It needs no other
library: it signs its requests itself.

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :storehouse, adapter: Storehouse.S3

  config :storehouse, Storehouse.S3,
    bucket: "my-app-uploads",
    region: "eu-west-1",
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
end
```

Another store: its `endpoint`, whose URLs name the bucket in their path
(`path_style`, the default with an endpoint), and the `public_url` of its
files when it serves them from a domain of yours or a CDN:

```elixir
config :storehouse, Storehouse.S3,
  bucket: "uploads",
  region: "auto",
  endpoint: "https://<account>.r2.cloudflarestorage.com",
  access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY"),
  public_url: "https://files.example.com"
```

A file's `url` is its public URL: of a public bucket, or of `public_url`.
A private bucket serves its files at signed URLs (see
[Private files](private_files.md)).

## In development

Two ways, as you like it.

**The local disk**, with nothing else to run: `Storehouse.Local` in
`config/dev.exs`, its plug in the endpoint, and a secret for direct
uploads and signed URLs. The browser uploads straight to the plug as it
would to a bucket, so the LiveView is the same in development and in
production.

```elixir
# config/dev.exs
config :storehouse, adapter: Storehouse.Local

config :storehouse, Storehouse.Local,
  root: Path.expand("../tmp/uploads", __DIR__),
  secret: "a development secret of at least 32 bytes"
```

**LocalStack** (or MinIO), S3 on your machine: `Storehouse.S3`, with its
endpoint and any keys.

```elixir
# config/dev.exs
config :storehouse, adapter: Storehouse.S3

config :storehouse, Storehouse.S3,
  bucket: "uploads",
  region: "us-east-1",
  endpoint: "http://localhost:4566",
  access_key_id: "test",
  secret_access_key: "test"
```

```sh
awslocal s3 mb s3://uploads
awslocal s3api put-bucket-cors --bucket uploads --cors-configuration file://cors.json
```

with the CORS rule of [Direct uploads](direct_uploads.md), for the
origin of your development server (`http://localhost:4000`).

In tests, the local disk, in a directory of the test's own:

```elixir
# config/test.exs
config :storehouse, Storehouse.Local,
  root: Path.expand("../tmp/test-uploads", __DIR__),
  secret: "a test secret of at least 32 bytes"
```

## Another store

Write a module with the three callbacks of `Storehouse.Adapter`
(`put/3`, `url/1` and `delete/1`), and the optional ones for direct
uploads and signed URLs (`presign_upload/3`, `read_head/2`,
`signed_url/2`) and for reading files back (`head/1`, `read_range/3`),
and name it in the config:

```elixir
config :storehouse, adapter: MyApp.Storage
```

or give it per call: `Storehouse.store(path, adapter: MyApp.Storage)`.
The `Storehouse.Adapter` docs have an example on `ExAws.S3`, for an app
that has it already.

Two rules for an adapter:

* Store each file with its checked content type (`meta.content_type`),
  and with `Content-Disposition: attachment` for every type that
  `Storehouse.Check.inline?/1` refuses. Without this, a store such as S3
  serves an uploaded HTML file inline, and it can run a script on the
  store's origin.
* The URL goes into your records and documents, so it must stay valid.
  Give a public or CDN URL, or a path of your app (for example
  `"/files/" <> key`) whose controller checks access and redirects to a
  short-lived signed URL.

## Keys

`Storehouse.key/2` makes `yyyy/mm/<uuid>-<safe name><extension>`. The
`:key` option of `Storehouse.store/2` (and of `Storehouse.Live.consume/3`)
makes another, a function of the name and the checked content type: a
prefix per account, for example.

```elixir
Storehouse.store(path, key: &("#{account.slug}/uploads/" <> Storehouse.key(&1, &2)))
```

An adapter refuses a key that `Storehouse.valid_key?/1` refuses: no `..`,
no absolute path, nothing but ASCII letters, digits, `.`, `-`, `_` and
`/`.

## Files from the server

A seed, an import or a file the app makes itself is stored the same way,
with no browser: `Storehouse.store/2` checks it, stores it and gives a
`Storehouse.File`. The file at the path stays where it is; the store has
its copy.

```elixir
{:ok, file} = Storehouse.store("priv/seeds/timeline.png", name: "Timeline.png")
```

## Reading files back

A file the app keeps is read back to work on it: its metadata read, a
smaller image made of it, sent on to another service, put in a zip.
`Storehouse.head/2` gives what the store knows of it without reading it,
and `Storehouse.read/2`, `Storehouse.stream/2` and
`Storehouse.download/3` give its bytes:

```elixir
{:ok, %{bytes: bytes, content_type: type}} = Storehouse.head(file)

# All at once, for a file of a known, small size.
{:ok, binary} = Storehouse.read(file, max_bytes: 50_000_000)

# A chunk at a time, into a zip or a response, with no more of it in memory than a chunk.
{:ok, stream} = Storehouse.stream(file, chunk_bytes: 8_388_608)
Enum.into(stream, File.stream!("export/" <> file.name))

# To the disk, for a tool that wants a path.
:ok = Storehouse.download(file, "/tmp/original.jpg")
```

The size a browser declares when it uploads straight to the store is a
claim. Give `:max_bytes`: the store is asked the file's size first, and
a larger file gives `{:error, {:too_large, bytes}}` before a byte of it is
read. A stream reads each chunk as it is taken, and raises
`Storehouse.ReadError` when the store fails halfway; `download/3` gives
that error as `{:error, reason}`, and leaves nothing at the path.

## Files from an address

`Storehouse.fetch/2` downloads a file and stores it: an image pasted by
its address, a file an agent names. It fetches only from the hosts you
give, `https` unless you allow `http`, follows a redirect only to one of
them, and stops a download as soon as it is larger than `:max_bytes`:

```elixir
Storehouse.fetch(url,
  hosts: ["images.example.com", "*.cdn.example.com"],
  accept: Storehouse.Check.images(),
  max_bytes: 10_000_000
)
```

Never give a host whose addresses people choose freely, and never one of
your own network: the server would fetch what they ask for.

## Previews

A PDF can show an image of its first page, a video a poster frame, a
large photo a thumbnail. Storehouse does not make them: give `:preview`,
a function of the stored file and the path of the file that returns the
URL of the image, or `nil`. It runs while the file is still there. With
Poppler and FFmpeg installed:

```elixir
defmodule MyApp.Previews do
  # The first page of a PDF (Poppler), the first frame of a video (FFmpeg).
  def make(%Storehouse.File{content_type: "application/pdf"} = file, path),
    do: store(file, ".png", &pdftoppm(path, &1))

  def make(%Storehouse.File{content_type: "video/" <> _} = file, path),
    do: store(file, ".jpg", &ffmpeg(path, &1))

  def make(_file, _path), do: nil

  defp pdftoppm(path, image),
    do: System.cmd("pdftoppm", ["-png", "-singlefile", "-r", "72", path, Path.rootname(image)])

  defp ffmpeg(path, image),
    do: System.cmd("ffmpeg", ["-v", "error", "-i", path, "-frames:v", "1", image])

  # Renders the image to a temporary file and stores it next to the file.
  defp store(file, extension, render) do
    image = Path.join(System.tmp_dir!(), "preview-#{System.unique_integer([:positive])}#{extension}")

    try do
      with {_output, 0} <- render.(image),
           {:ok, preview} <- Storehouse.store(image, key: fn _, _ -> file.key <> extension end) do
        preview.url
      else
        _error -> nil
      end
    after
      File.rm(image)
    end
  end
end
```

The URL goes into the file's `preview`. A result that is not a safe URL,
or an exception, gives no preview and logs a warning: the file is stored
either way. In a LiveView, the function runs in the LiveView's process:
give the tools a time limit.

## Deleted files

Storehouse does not know which of your records use a file. When one goes,
delete its file with `Storehouse.delete/2` (or let a job compare your
records with the store). Cleanup of the files nothing uses is on the
roadmap.
