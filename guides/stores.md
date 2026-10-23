# Stores

A store keeps the files: `Storehouse.Local` (the local disk, the
default), or an adapter of your own (`Storehouse.Adapter`) for S3,
another object store or a database.

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

## Another store

Write a module with the three callbacks of `Storehouse.Adapter`
(`put/3`, `url/1` and `delete/1`) and name it in the config:

```elixir
config :storehouse, adapter: MyApp.Storage
```

or give it per call: `Storehouse.store(path, adapter: MyApp.Storage)`.
The `Storehouse.Adapter` docs have a full example for S3.

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

An adapter written for Kotoba (`Kotoba.Storage`) or Hakushi
(`Hakushi.Storage`) has these same callbacks, and is a Storehouse adapter
as it is.

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
