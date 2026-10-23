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

## Several stores

An app often keeps files in more than one place: a public bucket behind a
CDN for avatars and a private one for invoices, large media on R2, an EU
customer's files in an EU bucket. Each is a module of the app's, with a
config of its own:

```elixir
defmodule MyApp.PrivateFiles, do: use Storehouse.S3
defmodule MyApp.Media, do: use Storehouse.S3
defmodule MyApp.Scratch, do: use Storehouse.Local

# config/runtime.exs
config :storehouse, MyApp.PrivateFiles, bucket: "acme-private", region: "eu-west-1", ...
config :storehouse, MyApp.Media, bucket: "acme-media", endpoint: "https://….r2.cloudflarestorage.com", ...
config :storehouse, MyApp.Scratch, root: "/var/lib/my_app/scratch", url_prefix: "/scratch", secret: ...
```

Give a store as `adapter:` to any call (`store/2`, `presign_upload/4`,
`verify_upload/2`, `signed_url/2`, `read/2`, `delete/2`, …,
`Storehouse.Live.allow/3`, `Storehouse.Redirect`), or to an Ecto field,
whose files are then made permanent, deleted and analyzed there:

```elixir
field :invoice, Storehouse.Ecto.File, store: MyApp.PrivateFiles
```

A second local store is served by a plug of its own:

```elixir
plug Storehouse.Local.Plug, store: MyApp.Scratch
```

`Storehouse.S3` and `Storehouse.Local` themselves stay the default store,
read from `config :storehouse, Storehouse.S3` (or `Storehouse.Local`), as
before. With `use Storehouse.S3, otp_app: :my_app`, a store's config is
`config :my_app, MyApp.PrivateFiles, …`.

A `Storehouse.File` does not record its store: the field (or the call)
names it.

## Moving to another store

`Storehouse.copy/2` copies a file from one store to another, under the
same key, and `Storehouse.copy_prefix/2` every file under a prefix
(`""` for all of them), several at once:

```elixir
Storehouse.copy_prefix("", from: MyApp.OldMedia, to: MyApp.Media, max_concurrency: 8)
#=> {:ok, %{copied: 1_204, skipped: 0, failed: []}}
```

or from the command line, with its progress:

```sh
mix storehouse.copy --from MyApp.OldMedia --to MyApp.Media
```

A file the destination has already, of the same size and checksum, is
skipped, so a copy can be stopped and run again, and copies only what is
missing. Two buckets the same credentials reach copy in S3 itself, with
no byte through the app; between other stores, a file goes a chunk at a
time, its checksum checked on the way.

To move without stopping, write to both while the old files are copied,
with a mirror: a store that writes to its primary and copies each file to
its mirrors, out of the request, retried until they answer
(`Storehouse.Mirror`).

```elixir
defmodule MyApp.Media do
  use Storehouse.Mirror, primary: MyApp.OldMedia, mirrors: [MyApp.NewMedia]
end
```

1. Use `MyApp.Media` as the store. Its copies are jobs of the app's
   runner ([Work out of the request](background.md)).
2. Copy what there was: `mix storehouse.copy --from MyApp.OldMedia --to MyApp.NewMedia`.
3. Swap them, `primary: MyApp.NewMedia, mirrors: [MyApp.OldMedia]`, so
   the app reads the new one; then use `MyApp.NewMedia` alone.

The same copy brings an account's files from production into
development, to look into a problem with real files:

```sh
mix storehouse.copy --from MyApp.ProductionMedia --to MyApp.Media --prefix accounts/42/
```

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

## In tests

`Storehouse.Memory` keeps files in memory, each test's its own, so tests
run with `async: true` never see each other's files:

```elixir
# config/test.exs
config :storehouse, adapter: Storehouse.Memory

# test/test_helper.exs
{:ok, _pid} = Storehouse.Memory.start_link()
ExUnit.start()

# test/support/data_case.ex, in its setup
Storehouse.Memory.checkout()
```

A task the test starts sees its files; another process, once
`Storehouse.Memory.allow/2` lets it (a LiveView's process, as Ecto's
sandbox does). `Storehouse.Test` asserts on what was stored, and
`Storehouse.Memory.fail_next/2` makes the next call of a callback fail:

```elixir
import Storehouse.Test

test "the avatar is stored", %{user: user} do
  {:ok, user} = Accounts.update_avatar(user, upload)
  assert_stored user.avatar.key
end

test "a store that fails", %{user: user} do
  Storehouse.Memory.fail_next(:put, :unavailable)
  assert {:error, _reason} = Accounts.update_avatar(user, upload)
end
```

An upload straight to the store has no server to go to: make the
browser's part of it with `Storehouse.Memory.put_upload/2`, then verify it
as in production.

The local disk, in a directory of the test's own, works too, for tests
that serve files through `Storehouse.Local.Plug`:

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

## The same file again

People upload the same file twice: a folder dropped again, a photo in two
places. Give `:existing`, a function of a checksum (SHA-256, in Base64, as
`Storehouse.checksum/1` gives it) that finds the file your app has with it,
and the same file is that file, `{:existing, file}`, with nothing stored
again:

```elixir
existing = fn checksum -> Repo.get_by(Photo, account_id: account.id, checksum: checksum) |> then(&(&1 && &1.file)) end

case Storehouse.store(path, owner: "accounts/#{account.id}", existing: existing) do
  {:ok, file} -> create_photo(account, file)
  {:existing, file} -> {:ok, find_photo(account, file)}
  {:error, reason} -> {:error, reason}
end
```

For an upload straight to the store, the browser reads the file's SHA-256
and sends it when it asks to upload: with `:checksum` and `:existing`,
`presign_upload/4` gives `{:existing, file}` for a file you have, and
nothing is uploaded. Any other upload is signed with the checksum, so the
store takes only the bytes that have it: a browser cannot claim another
file's checksum and be given that file. (S3, and the local plug, check
it. Allow its headers in the bucket's CORS: see Direct uploads.)

Two people may upload the same file at the same moment, before either is
saved. `verify_upload/2` with `:existing` checks again with the checksum
the store keeps, and gives `{:existing, file}` for the second, deleting its
copy.

Scope the function to the owner, as above: with `:owner`, Storehouse never
gives back another owner's file, whatever the function answers.

## Files that belong to an owner

In an app whose files belong to someone (an account, a workspace, a
site), give `:owner`, and each file's key is under the owner's prefix:

```elixir
{:ok, file} = Storehouse.store(path, owner: "accounts/#{account.id}")
file.key
#=> "accounts/42/2026/10/0b6…-palette.png"
```

`store/2`, `presign_upload/4`, `Storehouse.Live.allow/3` and its
`consume/3` take it. A key a browser sends back is only a claim: check it
is the owner's before you take it. `verify_upload/2` and
`Storehouse.Ecto.put_file/4` do, with `:owner`, and refuse another's with
`:not_owner`, leaving that file where it is. `Storehouse.owns?/2` checks a
key yourself.

`:room` is what the owner may still store, in bytes: a file larger than it
is refused with `{:error, :storage_full}`. Presigning checks the size the
browser declared; `verify_upload/2` checks the size the store has, and
deletes a file that does not fit.

```elixir
room = account.storage_limit - account.storage_used
Storehouse.presign_upload(name, type, bytes, owner: "accounts/#{account.id}", room: room)
```

`Storehouse.usage/2` counts an owner's files in the store itself, and
`Storehouse.delete_prefix("accounts/42/")` deletes them, when the account
goes.

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

## A zip of files

An export of an account's files, a folder to download: `Storehouse.Zip`
makes a zip of stored files and the app's own as a stream, with nothing
on the disk and no more than a chunk in memory, past 4 GB too (ZIP64).

```elixir
entries = [
  {"README.txt", "Your photographs, as of 23 October 2026.\n"}
  | for(photo <- photos, do: {"photos/" <> photo.name, {:stored, photo.key}})
]

# Its size before it is made: "3.2 GB, 1,204 photographs".
{:ok, bytes} = Storehouse.Zip.size(entries)

# Into the store as it is made (S3's multipart upload), then a link to it.
{:ok, zip} = Storehouse.Zip.store(entries, "exports/42/2026-10-23.zip")
{:ok, url} = Storehouse.signed_url(zip, expires_in: 86_400, disposition: :attachment)
```

`Storehouse.Zip.stream/2` gives the same zip as a stream, for a response
sent in chunks. A name is a path in the zip, never outside it: `..`, a
leading `/` and a backslash are refused.
## Files that expire

An export whose link is emailed for a day, a PDF to download for a
week, a report a job made: `expires_in:` stores a file that is deleted
after its time.

```elixir
{:ok, file} = Storehouse.store(path, expires_in: 7 * 86_400, owner: account.id)

Storehouse.expires_at(file)
#=> ~U[2026-10-30 12:00:00Z]

# Its link never outlives it; once it expired, there is none.
{:ok, url} = Storehouse.signed_url(file, expires_in: 30 * 86_400)
```

Its key is under `"expiring/"`, then the days it is kept, then when it
expires (`Storehouse.expiring_key/2`): `"expiring/7d/1792843200/42/…"`.
On S3, give the bucket one lifecycle rule for each number of days you
use, on its prefix:

```json
{"Rules": [
  {"ID": "storehouse-expiring-1d", "Status": "Enabled", "Filter": {"Prefix": "expiring/1d/"}, "Expiration": {"Days": 1}},
  {"ID": "storehouse-expiring-7d", "Status": "Enabled", "Filter": {"Prefix": "expiring/7d/"}, "Expiration": {"Days": 7}}
]}
```

On the local disk, and a store with no lifecycle rules, `Storehouse.Sweeper`
deletes them once their time has come.

A file made in the store as a stream takes an expiring key too:
`Storehouse.expiring_key("exports/42.zip", 86_400)`.

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
delete its file with `Storehouse.delete/2`, or with
`Storehouse.delete_later/2`, a job of the app's runner, tried again until
the store answers ([Work out of the request](background.md)).

### Many files at once

Keys under a prefix go together: an account's (`"accounts/42/"`, with the
`:key` option above), every version of a file. `Storehouse.list/2` gives
them, a page at a time, and `Storehouse.delete_prefix/2` deletes them, a
thousand at a time on S3:

```elixir
{:ok, files} = Storehouse.list("accounts/42/")
Enum.sum_by(files, & &1.bytes)

{:ok, count} = Storehouse.delete_prefix("accounts/42/")
:ok = Storehouse.delete_prefix_later("accounts/42/")
```

An empty prefix, or `"/"`, is refused: nothing deletes a whole store.

### Temporary files never saved

A bucket's lifecycle rule deletes the files under the temporary prefix
(see the Ecto guide). The local disk, and a store with no lifecycle
rules, has `Storehouse.Sweeper`: every hour, on one node of a cluster,
it deletes the temporary files older than `:max_age` seconds.

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Storehouse.Sweeper, max_age: 86_400},
  MyAppWeb.Endpoint
]
```

`Storehouse.Sweeper.sweep/1` does the same at once, from a scheduled job
of yours.
