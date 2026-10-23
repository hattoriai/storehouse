# Direct uploads

A direct upload goes from the browser straight to the store: the file
never passes through your app, however large it is. Your app signs the
upload (where, what type, what size, for how long), the browser sends the
file, and when it is there, Storehouse reads its first bytes and checks
them. A file that is not what it said it was is deleted.

`Storehouse.S3` and `Storehouse.Local` both take direct uploads: in
development, the browser uploads to your app's own plug exactly as it
would to a bucket.

## In a LiveView

`Storehouse.Live.allow/3` in place of `allow_upload/3`, and
`Storehouse.Live.consume/3` as for any upload:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:photos, [])
   |> Storehouse.Live.allow(:photos,
     accept: ~w(.png .jpg .jpeg .gif .webp),
     max_file_size: 50_000_000,
     max_entries: 10,
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

and Storehouse's uploader in `assets/js/app.js`:

```javascript
import {Uploaders} from "storehouse"

let liveSocket = new LiveSocket("/live", Socket, {
  uploaders: Uploaders,
  params: {_csrf_token: csrfToken}
})
```

(`"storehouse"` is the package in `deps/storehouse`, as `"phoenix"` and
`"phoenix_live_view"` are.) With uploaders of your own:
`{...Uploaders, ...yours}`.

`allow/3` signs direct uploads when the store does; with a store that
does not (an adapter of yours with the three callbacks), or with
`mode: :server`, the files come to the LiveView as a plain upload, and
`consume/3` stores them. Your LiveView is the same either way.

## Streamed through the app: mode: :stream

When the browser cannot reach the store (a bucket with no CORS, a store
in a private network, LocalStack inside a container), or you would rather
it did not, `mode: :stream` sends the file over the LiveView's socket, and
on to the store as each chunk comes (`Storehouse.Live.Writer`):

```elixir
Storehouse.Live.allow(socket, :videos,
  mode: :stream,
  types: ["video/mp4", "video/webm"],
  accept: ~w(.mp4 .webm),
  max_file_size: 2_000_000_000,
  auto_upload: true,
  progress: &handle_progress/3
)
```

Nothing of the file is written to the app's disk. To S3 it goes in the
parts of a multipart upload (8 MB each, `:part_size` of
`Storehouse.S3`), each with its checksum, at most two on their way while
the next chunks arrive, from a process of their own; the upload waits
when they are, so a fast browser never fills the app's memory. Its first
bytes are checked as soon as they are there: a file that is not what it
said stops, and nothing of it stays in the store. The whole file's
checksum is computed on the way. No uploader in `app.js`: it is
LiveView's own.

## What is signed

Each upload is signed for:

* its **key**, a new one, whose extension is the claimed type's
  (`Storehouse.Check.claimed/1`): a type Storehouse does not know is a
  download, with a `.bin` key;
* its **type**: the store keeps the file with it, and with
  `Content-Disposition: attachment` for every type a browser should not
  show;
* its **size**, exactly: the store refuses a body of another size. The
  upload's `max_file_size` limits it first;
* **ten minutes** to start (`:expires_in`).

## What is checked

When the upload is done, `consume/3` reads the first bytes of the file
in the store (`Storehouse.verify_upload/2`). A file whose bytes are not of
the type it was signed for (an HTML page sent as a PNG), of a type
`:accept` refuses, or over `:max_pixels`, is deleted from the store, and
its result is `{:error, :not_accepted}` or `{:error, :too_large}`.

Until then, the file is in the store but in nothing of yours: keep only
the files `consume/3` gives you.

## The bucket's CORS

The browser sends the file to the bucket's origin: the bucket must allow
your app's origin to `PUT`, with the headers Storehouse signs:

```json
[
  {
    "AllowedOrigins": ["https://my-app.example.com"],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["content-type", "content-disposition"],
    "MaxAgeSeconds": 3600
  }
]
```

Uploads presigned with a `:checksum` (see "The same file again" in the
Stores guide) also send `x-amz-checksum-sha256` and
`x-amz-sdk-checksum-algorithm`: add them to `AllowedHeaders`. A store with
a `:cache_control` sends `cache-control` too. Parts of a multipart upload
(`Storehouse.presign_multipart/4`) send `x-amz-checksum-sha256`; the app
reads their ETags from the bucket, so the browser needs no
`ExposeHeaders`.

On AWS, in the bucket's permissions; on R2, in the bucket's settings; on
LocalStack, `awslocal s3api put-bucket-cors`. `Storehouse.Local` needs
none: the plug is your app.

If your app sends a `Content-Security-Policy`, allow the store's origin
in `connect-src`.

## Very large files, in parts

`Storehouse.presign_multipart/4` starts an upload that the browser sends
straight to the bucket in parts, for files past what one `PUT` sends
well: checked before a byte is sent as `presign_upload/4` checks one,
each part signed with its checksum (`presign_parts/4`), what the store
has listed for a browser that comes back (`multipart_parts/3`), then put
together and checked as `verify_upload/2` checks one
(`complete_multipart/4`). `Storehouse.Plug.Multipart` is the same as
JSON endpoints, and the JavaScript client sends large files through it:
see "Very large files, in parts" in [Uploads from any client](any_client.md).

## Without LiveView

`Storehouse.presign_upload/4` signs an upload, and
`Storehouse.verify_upload/2` checks it, for a controller and a form of
your own, or an API:

```elixir
{:ok, %{key: key, method: "PUT", url: url, headers: headers}} =
  Storehouse.presign_upload(params["name"], params["type"], params["size"],
    accept: Storehouse.Check.images(),
    max_bytes: 50_000_000
  )

# The client sends the file: PUT url, with headers, and the file as the body.

{:ok, file} = Storehouse.verify_upload(key, name: params["name"], accept: Storehouse.Check.images())
```
