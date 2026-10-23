# Serving

An uploaded file is content from a user. Served as it came, an HTML file
or an SVG would run its scripts on your app's origin. Storehouse's keys
never end in an active extension (the extension is the checked type's),
and `Storehouse.Local.Plug` serves the files of the local store with the
headers that keep them passive.

## The plug

In the endpoint, before the router:

```elixir
plug Storehouse.Local.Plug
```

or in the router:

```elixir
forward "/uploads", Storehouse.Local.Plug, at: "/"
```

It answers `GET` and `HEAD` under its path, and passes every other
request on. Each file goes with:

* its checked type, from its extension (an extension not in the list is
  `application/octet-stream`);
* `X-Content-Type-Options: nosniff` and `Content-Security-Policy:
  default-src 'none'; sandbox`;
* `Content-Disposition: inline` for the images, PDF and videos, and
  `attachment` (a download) for every other type;
* `Cache-Control: private, max-age=3600` (`:max_age`);
* `Accept-Ranges: bytes`, and `206` for a single range: a video needs
  ranges to seek, and Safari to play at all.

A path with a segment that is not a valid key segment gives `400`; a key
with no regular file (a directory, a symbolic link) gives `404`. Do not
serve the directory with `Plug.Static`: it sends none of these headers.

## Files behind a login

The endpoint plug and a `forward` serve every file to every visitor. When
only the people of an account may see its files, and the account is a
segment of the path (`/:org_slug/...`), serve the files from a route in
the scope that checks the login, and start each key with the path of that
route:

```elixir
# config/config.exs
config :storehouse, Storehouse.Local, url_prefix: "/"

# Keys like "acme/uploads/2026/10/<uuid>-name.png"
Storehouse.Live.consume(socket, :photos, key: &("#{slug}/uploads/" <> Storehouse.key(&1, &2)))

# The router, in the scope that requires a member of :org_slug
get "/uploads/*key", Storehouse.Local.Plug, [at: "/"], alias: false
```

The URL of a file is then its key, the router lets only the account's
people reach it, and the plug serves the file at that path under the
root. `forward` cannot take a path with a dynamic segment, so use a `get`
route (`alias: false` keeps the scope's alias off the module).

## Your page's CSP

If your app sends a `Content-Security-Policy`, allow the files' origin in
`img-src` (images and previews), `media-src` (video) and `object-src`
(PDF).

## Drawing the files in the browser

A page that reads a file's bytes (a canvas exported to PNG, an image
edited in the browser) can read only files of its own origin, or of an
origin that allows it with CORS. Serve them from your app, or set CORS
headers on your store.
