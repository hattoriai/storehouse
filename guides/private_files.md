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

## Disposition

A signed URL can name a download (`filename:`), or ask for one
(`disposition: "attachment"`). It never shows inline a type a browser
should not show: an HTML file is a download whatever the URL asks.
