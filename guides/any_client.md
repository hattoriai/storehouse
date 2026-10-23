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
scope "/files" do
  pipe_through [:api, :require_user]

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
              "url": "https://bucket…", "headers": {"content-type": "image/jpeg", "content-disposition": "inline"}}},
  {"error": "not_accepted"}
]}
```

or `{"existing": {…file…}}` for a file the app has, which is not
uploaded. The browser sends each file with exactly the `method` and
`headers` given (with a checksum, those include `x-amz-checksum-sha256`:
the store takes only those bytes).

`POST /files/register`:

```json
{"uploads": [{"key": "accounts/42/2026/10/0b6…-harbour.jpg", "name": "harbour.jpg"}]}
```

answers `200` with `{"uploads": [...]}`, the values your `:then` gives (or,
without it, `{"file": {…}}`, `{"existing": {…}}` or `{"error": code}`).
The same bytes twice in one batch are one file: the second's copy is
deleted. A key of another owner's file is refused with `not_owner`, and
that file left as it is.

Errors are codes, for the frontend to say in its own words:
`not_accepted`, `too_large`, `storage_full`, `invalid_checksum`,
`not_owner`, `invalid_item`, `too_many` (a `413` for the whole batch), and
`upload_failed`. A body that is not a batch is a `400`.

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
    return result.upload
  }
})

uppy.on("complete", ({successful}) =>
  fetch("/files/register", {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken},
    body: JSON.stringify({uploads: successful.map(f => ({key: f.meta.key, name: f.name}))})
  })
)
```

## Without the plugs

`Storehouse.Batch.presign/2` and `register/2` are the plugs' work, for an
app that keeps its own controllers or speaks GraphQL.
