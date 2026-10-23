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

## A CDN in front

A CDN (Cloudflare, Fastly, CloudFront) keeps a file close to its readers.
Storehouse's keys are never reused, so a stored file never changes: tell
the CDN and the browser to keep it for a year.

```elixir
config :storehouse, Storehouse.S3,
  bucket: "my-app-uploads",
  # …
  public_url: "https://files.example.com",
  cache_control: "public, max-age=31536000, immutable"
```

The bucket then keeps that `Cache-Control` with every file and serves it
with it, however the file came in: stored, uploaded from the browser (the
header is signed, so add `cache-control` to the bucket's CORS
`AllowedHeaders`), streamed in, or promoted from the cache. A call's
`:cache_control` (`Storehouse.store/2`, `Storehouse.presign_upload/4`)
takes the store's place for one file. `Storehouse.Local.Plug` has
`cache_control:` of its own, and `Storehouse.Variants.Plug` sends a year
already.

### Forgetting a file deleted

A file never changes, but it can go: a person deletes a photograph, or
their account. A CDN that keeps it for a year would go on serving it.
`Storehouse.Purge` tells the CDN, after each `Storehouse.delete/2`, which
URLs to forget: the file's own, its variants', and those of your routes.

```elixir
config :storehouse, Storehouse.Purge,
  purger:
    {Storehouse.Purge.Cloudflare,
     zone_id: System.fetch_env!("CLOUDFLARE_ZONE_ID"),
     api_token: System.fetch_env!("CLOUDFLARE_API_TOKEN")},
  base_url: "https://example.com",
  urls: &["https://example.com/files/#{&1}"]
```

The purge runs as a job of the app's runner, and is retried until the CDN
answers. Its job holds the URLs; the token is read from the config when it
runs, so it is never stored in a job table. Deleting the files under a
prefix (an account's) gives the prefix's URLs, for a CDN that purges by
prefix (`by: [:urls, :prefixes]` on Cloudflare's Enterprise plan).

**By tag.** With `cache_tag: true`, `Storehouse.Proxy`,
`Storehouse.Variants.Plug` and `Storehouse.Local.Plug` send each file's
`Cache-Tag`, and its variants are sent with their original's.
`by: [:tags]` then forgets a file and all of its variants in one request,
whatever URLs they were served at.

A CDN without an API that Storehouse knows takes a purger of your own: a
module of `Storehouse.Purge` with one function, `purge/2`.

## Your page's CSP

If your app sends a `Content-Security-Policy`, allow the files' origin in
`img-src` (images and previews), `media-src` (video) and `object-src`
(PDF).

## Drawing the files in the browser

A page that reads a file's bytes (a canvas exported to PNG, an image
edited in the browser) can read only files of its own origin, or of an
origin that allows it with CORS. Serve them from your app, or set CORS
headers on your store.
