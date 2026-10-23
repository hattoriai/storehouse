# Private files

A file is public when anyone with its URL gets it: a public bucket, a
local store whose plug serves every file. Its URL lives in your records
and documents, and works for as long as the file does.

A private file is served at a **signed URL**, valid for a few minutes:
the store gives it to whoever your app gives it to, until it expires.

```elixir
{:ok, url} = Storehouse.signed_url(file.key)
{:ok, url} = Storehouse.signed_url(file.key, expires_in: 60, filename: "Invoice 2026-10.pdf")
```

`Storehouse.S3` signs them for a private bucket (the bucket's default),
and `Storehouse.Local` for its plug, with the store's secret:

```elixir
config :storehouse, Storehouse.Local,
  root: "/var/lib/my_app/uploads",
  secret: System.fetch_env!("STOREHOUSE_SECRET")

# The endpoint: every file only at a URL the store signed.
plug Storehouse.Local.Plug, private: true
```

## A lasting URL: Storehouse.Redirect

A signed URL expires: keep the file's key, never the signed URL. Where a
URL must last (in a document, an email, an `<img>` of a page that stays
open), give one of your app's that checks the person and redirects to a
fresh signed URL:

```elixir
# The router, in the scope that has the person
forward "/files", Storehouse.Redirect, authorize: &MyAppWeb.Files.allowed?/2
```

```elixir
defmodule MyAppWeb.Files do
  # Whether the person may see the file.
  def allowed?(conn, key), do: MyApp.Files.visible?(conn.assigns.current_scope, key)
end
```

`/files/<key>` then redirects to the file, for a person who may see it,
and gives `404` to anyone else (so no one learns which files exist).
`?download=1` asks for a download, with the file's name.

The URL your records keep is then `"/files/" <> file.key`, not the
file's `url` (with `Storehouse.Local`, keep its `url_prefix` the plug's
path, apart from the redirect's: signed URLs are made on it).

## Through the app: Storehouse.Proxy

`Storehouse.Redirect` sends the person to the bucket. `Storehouse.Proxy`
checks the person the same way, then streams the file from the store
through the app, so the bucket's address never leaves it:

```elixir
forward "/files", Storehouse.Proxy, authorize: &MyAppWeb.Files.allowed?/2
```

It reads the file a part at a time (4 MiB by default), so a large file
never sits in memory. It answers a `Range` with `206`, and sends an `ETag`
(from the file's SHA-256) and `Last-Modified`, so a browser that still has
the file gets `304` and no byte is read. It uses the same passive headers
as `Storehouse.Local.Plug`. Use it when the bucket must stay out of sight,
when the files go through a CDN that cannot sign, or when a store's
signed URLs are not wanted at all.

A file only some may see is sent with
`Cache-Control: private, max-age=0, must-revalidate` by default, so that a
CDN never keeps it for someone else. For a public bucket kept behind the
app, let everyone in and let the CDN keep the files:

```elixir
forward "/files", Storehouse.Proxy,
  authorize: true,
  cache_control: "public, max-age=31536000, immutable",
  cache_tag: true
```

## Disposition

A signed URL can name a download (`filename:`), or ask for one
(`disposition: "attachment"`). It never shows inline a type a browser
should not show: an HTML file is a download whatever the URL asks.
