# Storehouse

![Storehouse — Files for Phoenix](https://raw.githubusercontent.com/hattoriai/storehouse/main/media/banner.png)

Storehouse keeps the files of a Phoenix app: the photos people upload,
the attachments of a document, the images on a canvas, the files an app
makes itself. Each file is checked by its bytes, stored under a new, safe
key, in a store of your choosing, and served so that it can never run a
script on your app's origin.

It is the storage of the Hattori libraries, taken out of them: Kotoba's
attachments and Hakushi's images keep their files with it, and so can
your app.

> **Status: early release.** Checking, storing, the local store and its
> plug, files from an address, and LiveView uploads are here. Before 1.0,
> a minor version may change the API; see the roadmap for what comes
> next.

## Installation

```elixir
def deps do
  [
    {:storehouse, "~> 0.1"}
  ]
end
```

Storehouse needs Elixir 1.18 or later and, for `Storehouse.Live`,
Phoenix LiveView 1.1 or later. The rest works in any Plug app.

It gives your app:

* **files checked by their bytes**, not their names: PNG, JPEG, GIF and
  WebP images (with their width and height, a phone's photo turned as
  its EXIF says), PDF, MP4 and WebM video, ZIP and Office documents, and
  plain text. Anything else (HTML, SVG, JavaScript, a page renamed
  `.png`) is `application/octet-stream`, a download, or refused;
* **safe keys**: `yyyy/mm/<uuid>-<safe name><extension>`, whose
  extension comes from the checked type, so a key never ends in `.html`;
  an adapter refuses any key that could leave its root;
* **stores of your own**: three callbacks (`put`, `url`, `delete`); the
  local disk is built in, and S3 is a page of code;
* **serving that is safe**: `Storehouse.Local.Plug` sends the checked
  type, `nosniff`, a sandboxing CSP, downloads for every type a browser
  should not show, and byte ranges, for video;
* **LiveView uploads, stored**: `Storehouse.Live.consume/3` stores each
  finished entry once, cancels those the upload refused, and gives you a
  result for each;
* **files from an address**, from the hosts you allow only, with
  redirects checked and the download stopped at the size limit: an image
  pasted by its address, a file an agent names;
* **limits**: the largest file, the most pixels of an image, the types
  you take;
* **previews**: a function of yours gives a smaller image of a file (a
  thumbnail, a PDF's first page), kept with it.

## A sketch

```elixir
# config/runtime.exs
config :storehouse, Storehouse.Local, root: "/var/lib/my_app/uploads"

# lib/my_app_web/endpoint.ex, before the router
plug Storehouse.Local.Plug
```

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

In a LiveView:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:photos, [])
   |> allow_upload(:photos,
     accept: ~w(.png .jpg .jpeg .gif .webp),
     max_file_size: 10_000_000,
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

From an address:

```elixir
Storehouse.fetch("https://images.example.com/board.png",
  hosts: ["images.example.com"],
  accept: Storehouse.Check.images(),
  max_bytes: 10_000_000
)
```

The guides: [Stores](guides/stores.md) (the local disk, S3, private
files), [Serving](guides/serving.md) and [LiveView](guides/liveview.md).

## Kotoba and Hakushi

Kotoba (`Kotoba.Storage`) and Hakushi (`Hakushi.Storage`) had stores of
their own, with these same three callbacks: an adapter written for
either of them is a Storehouse adapter as it is. As they move onto
Storehouse, each keeps its own config working, and an app with both
sets its store once:

```elixir
config :storehouse, adapter: MyApp.Storage
```

## Roadmap

* **Uploads straight to the store.** LiveView's external uploads with
  presigned URLs, so that a large file never goes through the app.
* **Signed, expiring URLs** for private files, with a plug that checks
  them.
* **Records of files** (optional, with Ecto): what is stored, and what
  uses it.
* **Cleanup**: the files nothing uses any more, deleted after a while
  (so that an undo still finds them).
* **Previews made for you**: thumbnails with an optional image library,
  cached.
* **More types**: audio, and the length of a video.

## Development

```sh
mix deps.get
mix test
mix credo --strict
mix dialyzer
```

## License

MIT. See [LICENSE](https://github.com/hattoriai/storehouse/blob/main/LICENSE).
