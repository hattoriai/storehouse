# Uploads from any client

A frontend that is not a LiveView (React, Vue, Svelte, a native app)
uploads straight to the store in three steps around its own code:

1. **Presign.** It asks your app to sign uploads of its files: their
   names, types, sizes and, if it can read them, their SHA-256.
2. **Send.** It sends each file to the store, at the URL signed for it.
3. **Register.** It gives your app the keys, and your app checks each file
   in the store by its bytes and keeps its records.

`Storehouse.Plug.Presign` and `Storehouse.Plug.Register` answer the first
and the last, in JSON, a batch at a time (up to 100 files).

## The routes

```elixir
# lib/my_app_web/router.ex
pipeline :files do
  plug :accepts, ["json"]
  plug :fetch_session
  # The browser's session is its cookie: the CSRF token, which the
  # JavaScript client sends from the page, says the request is the page's.
  plug :protect_from_forgery
end

scope "/files" do
  pipe_through [:files, :require_user]

  forward "/presign", Storehouse.Plug.Presign,
    owner: &MyAppWeb.Files.owner/1,
    room: &MyAppWeb.Files.room/1,
    existing: &MyAppWeb.Files.existing/2,
    accept: Storehouse.Check.images(),
    max_bytes: 50_000_000

  forward "/register", Storehouse.Plug.Register,
    owner: &MyAppWeb.Files.owner/1,
    room: &MyAppWeb.Files.room/1,
    existing: &MyAppWeb.Files.existing/2,
    accept: Storehouse.Check.images(),
    then: &MyAppWeb.Files.registered/2
end
```

```elixir
defmodule MyAppWeb.Files do
  def owner(conn), do: "accounts/#{conn.assigns.current_account.id}"
  def room(conn), do: MyApp.Accounts.room_left(conn.assigns.current_account)

  def existing(conn, checksum),
    do: MyApp.Photos.file_with_checksum(conn.assigns.current_account, checksum)

  # One JSON value per upload, in order: the app's records.
  def registered(conn, results) do
    Enum.map(results, fn
      {:ok, file} -> %{"photo" => MyApp.Photos.create!(conn.assigns.current_account, file) |> render()}
      {:existing, file} -> %{"photo" => MyApp.Photos.get_by_file!(file) |> render()}
      {:error, code} -> %{"error" => to_string(code)}
    end)
  end
end
```

A frontend that signs in with a token of its own (an `authorization`
header, a native app) has no cookie for another site to send, and no
CSRF token to check: its pipeline is `:api` and its authentication.

Each option that depends on the request is a function of the conn: whose
files these are (`:owner`), the bytes they may still store (`:room`,
shared by the batch: each file takes its size from what the next sees),
and the file the app already has with a checksum (`:existing`). Every
other option is `Storehouse.Batch`'s, as it is.

## The contract

`POST /files/presign`:

```json
{"uploads": [
  {"name": "harbour.jpg", "type": "image/jpeg", "bytes": 35367, "checksum": "62a6…"},
  {"name": "notes.txt", "type": "text/plain", "bytes": 12}
]}
```

answers `200`, one result per upload, in order:

```json
{"uploads": [
  {"upload": {"key": "accounts/42/2026/10/0b6…-harbour.jpg", "method": "PUT",
              "url": "https://bucket…", "headers": {"content-type": "image/jpeg", "content-disposition": "inline"},
              "token": "SFMyNTY…"}},
  {"error": "not_accepted"}
]}
```

or `{"existing": {…file…}}` for a file the app has, which is not
uploaded. The browser sends each file with exactly the `method` and
`headers` given (with a checksum, those include `x-amz-checksum-sha256`:
the store takes only those bytes), then gives the `key` and the `token`
back to register it.

`POST /files/register`:

```json
{"uploads": [{"key": "accounts/42/2026/10/0b6…-harbour.jpg", "token": "SFMyNTY…", "name": "harbour.jpg"}]}
```

answers `200` with `{"uploads": [...]}`, the values your `:then` gives (or,
without it, `{"file": {…}}`, `{"existing": {…}}` or `{"error": code}`).
The same bytes twice in one batch are one file: the second's copy is
deleted.

The token is the upload's key and owner, signed with your endpoint's
`secret_key_base` when it was presigned, and valid for a day. A key
without its token, or with another's, is refused with `invalid_token`,
and the file at it is left as it is: a request can name only an upload
your app signed for that owner, never a file already stored, or one of
another person of a workspace they share.

Both endpoints take `application/json` only (anything else is a `415`),
so that a page of another site cannot send them a form.

Errors are codes, for the frontend to say in its own words:
`not_accepted`, `too_large`, `storage_full`, `invalid_checksum`,
`not_owner`, `invalid_token`, `invalid_item`, `too_many` (a `413` for the
whole batch), and `upload_failed`. A body that is not a batch is a `400`.

## The JavaScript client

`storehouse/client` (`@hattoriai/storehouse/client` from npm, beside the LiveView
uploader) does the browser's part, with no dependencies:

```javascript
// In a Phoenix app; from npm, "@hattoriai/storehouse/client".
import {createUploadQueue} from "storehouse/client"

const queue = createUploadQueue({
  presignUrl: "/files/presign",
  registerUrl: "/files/register",
})

input.addEventListener("change", () => {
  for (const upload of queue.add(input.files)) {
    upload.onProgress((fraction) => show(upload.file.name, fraction))
    upload.result.then((result) => {
      if (result.status === "registered") addPhoto(result.value.photo)
      else if (result.status === "existing") highlight(result.value)
      else if (result.status === "error") say(upload.file.name, result.error)
    })
  }
})
```

- The page's CSRF token goes with each request to the app, from the
  `<meta name="csrf-token">` of Phoenix's root layout, as
  `Plug.CSRFProtection` expects it. `headers` adds others (an
  `authorization` for an API with tokens) or gives the token itself.
- Each file's SHA-256 is read in a Web Worker (the page does not freeze
  on a large file), and sent with its presign: a file the app has comes
  back as `existing`, and is never uploaded.
- The files added together are presigned in one request, sent to the
  store four at a time (`concurrency`), each sent again after a network
  error or the store's `5xx` (`retries`), and registered in batches: as
  soon as ten are done (`registerBatchSize`), or 400 ms after the first
  (`registerMaxWaitMs`).
- Each upload has its `result`, a promise of `{status, value}` or
  `{status: "error", error}` (the code), its progress from 0 to 1 (1 only
  once the store has the file), and `cancel()`. `queue.on("registered", …)`
  and the like follow them all.

Its types are in `storehouse-client.d.mts`. Give `fetch` and `put` of your
own to send the requests another way.

### Very large files, in parts

A file of a few gigabytes (a video, an archive to import) should not be
one `PUT`: a dropped connection would start it again, and S3 takes at
most 5 GB in one. With `Storehouse.Plug.Multipart` in the router, the
client sends such files in parts:

```elixir
forward "/files/multipart", Storehouse.Plug.Multipart,
  owner: &MyAppWeb.Files.owner/1,
  room: &MyAppWeb.Files.room/1,
  max_bytes: 20_000_000_000
```

```javascript
const queue = createUploadQueue({
  presignUrl: "/files/presign",
  registerUrl: "/files/register",
  multipartUrl: "/files/multipart",
})
```

- A file of `multipartThreshold` or more (100 MiB by default) goes in
  parts, of the size the app gives (16 MiB by default), four at a time
  (`partConcurrency`). Each part is sent with its SHA-256, which the
  bucket checks, and each is retried on its own after a network error or
  a `5xx` (`partRetries`).
- The upload is remembered in `localStorage`: after a reload or a crash,
  the same file added again carries on from the parts the store has. Its
  result is the same as a file sent whole. `storage: null` remembers
  nothing.
- The app completes it: it puts together the parts the store has, never
  what the browser says, refuses a size other than the file's, and checks
  the file as `Storehouse.Plug.Register` checks one.
- `cancel()` gives the upload up, and its parts are deleted.

Uploads never completed keep their parts in the bucket, and S3 bills
them: give the bucket a lifecycle rule that aborts them
(`AbortIncompleteMultipartUpload`, after a day), or run
`Storehouse.Sweeper`, which aborts those older than its `:max_age`.

```json
{"Rules": [{"ID": "storehouse-multipart", "Status": "Enabled", "Filter": {},
            "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}}]}
```

## tus, through the app

[tus](https://tus.io) is an open protocol of resumable uploads, with
clients for the browser (Uppy's Tus plugin, tus-js-client), iOS, Android
and the desktop. `Storehouse.Tus.Plug` is a tus server (1.0.0, with
creation, creation-with-upload, termination and expiration):

```elixir
# lib/my_app/application.ex: the uploads in progress
children = [MyApp.Repo, Storehouse.Tus, MyAppWeb.Endpoint]

# lib/my_app_web/router.ex, behind your authentication
forward "/files/tus", Storehouse.Tus.Plug,
  owner: &MyAppWeb.Files.owner/1,
  room: &MyAppWeb.Files.room/1,
  accept: ["video/mp4", "video/quicktime"],
  max_bytes: 20_000_000_000,
  then: &MyAppWeb.Files.uploaded/2
```

```javascript
import Uppy from "@uppy/core"
import Tus from "@uppy/tus"

new Uppy().use(Tus, {endpoint: "/files/tus", headers: {"x-csrf-token": csrfToken}})
```

The bytes go through the app, unlike the routes above, so tus suits
clients that speak it already, and stores the browser cannot send to
straight (the local disk). A connection lost halfway carries on from the
last byte the app has. On S3, they go into the bucket's multipart upload
a part at a time as they come, with nothing on the app's disk; on the
local disk, into a file stored when it is whole. Either way the file is
checked as every upload is, its claimed type and size when it is
created, its type by its first bytes when it is whole. `:then` is given
the stored file, to save it in a record.

The uploads in progress are kept in ETS, one node's; behind a load
balancer of several nodes, keep them in your database with a module of
`Storehouse.Tus.State` given as `state:`. Those not finished in a day
(`:expires_in`) are given up, their bytes with them.

## Uppy

Uppy's [AWS S3 plugin](https://uppy.io/docs/aws-s3/) asks for one file's
parameters at a time: a batch of one.

```javascript
uppy.use(AwsS3, {
  shouldUseMultipart: false,
  async getUploadParameters(file) {
    const response = await fetch("/files/presign", {
      method: "POST",
      headers: {"content-type": "application/json", "x-csrf-token": csrfToken},
      body: JSON.stringify({uploads: [{name: file.name, type: file.type, bytes: file.size}]})
    })
    const {uploads: [result]} = await response.json()
    if (result.error) throw new Error(result.error)
    file.meta.key = result.upload.key
    file.meta.token = result.upload.token
    return result.upload
  }
})

uppy.on("complete", ({successful}) =>
  fetch("/files/register", {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken},
    body: JSON.stringify({uploads: successful.map(f => ({key: f.meta.key, token: f.meta.token, name: f.name}))})
  })
)
```

## Without the plugs

`Storehouse.Batch.presign/2` and `register/2` are the plugs' work, for an
app that keeps its own controllers or speaks GraphQL.
