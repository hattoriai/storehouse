# After the upload

Once a file is stored, an app often wants to know more of it than its
type and size: an image's EXIF, its main colours, a PDF's pages, a
video's length. Each is a step, an analyzer of your own or Storehouse's
(`Storehouse.Analyzer`), and what it made of the file is kept in the
file's `:analysis`, by the step's name: a `Storehouse.Analysis`, with its
status (`:ok`, `:skipped`, `:failed`), its result, why it failed and when
it ran. It is apart from the file's metadata, which is the app's alone.
Nothing runs unless you name the steps.

## A step

```elixir
defmodule MyApp.Analyzers.Pages do
  @behaviour Storehouse.Analyzer

  # The file, on the local disk.
  @impl true
  def analyze(%Storehouse.File{content_type: "application/pdf"}, path, _opts) do
    case System.cmd("pdfinfo", [path]) do
      {output, 0} ->
        [_, pages] = Regex.run(~r/Pages:\s+(\d+)/, output)
        {:ok, %{"pages" => String.to_integer(pages)}}

      {output, _status} ->
        {:error, output}
    end
  end

  # Not a PDF: nothing to read.
  def analyze(_file, _path, _opts), do: :skip
end
```

Its result goes under its name, `"pages"` (the module's last part; a
`name/0` gives another). A step that needs only what the store knows, not
the file's bytes, says so with `needs_file?/0`, and nothing is downloaded
for it: `Storehouse.Analyzer.Size` asks the store a file's real size and
type, for a file uploaded straight to it.

## At once

```elixir
{:ok, file} = Storehouse.store(path, analyze: [MyApp.Analyzers.Pages])
Storehouse.File.analyzed(file, "pages")
#=> %{"pages" => 12}

{:ok, file} = Storehouse.analyze(file, [MyApp.Analyzers.Pages, Storehouse.Analyzer.Size])
```

`store/2` runs the steps on the file it just stored, from its path. Later,
`Storehouse.analyze/3` reads the file from the store once, for all the
steps that need it, to a temporary file it removes after them.

Each step runs once: a step whose result the file has is skipped
(`force: true` runs it again). A step that fails, or raises, is `:failed`, with
why, and leaves the others' results; the next run tries it again. `:skip`
is `:skipped`. The result is the step's own map, as it gave it: a key of
its own named `"error"` is a result like any other.

```elixir
Storehouse.File.analysis(file, "pages")
#=> %Storehouse.Analysis{status: :ok, result: %{"pages" => 12}, error: nil, at: ~U[…]}
```

## Later, and saved

Most analysis should not hold up a request. `Storehouse.analyze_later/3`
runs it as a job of the app's runner (Oban's when the app runs Oban, see
[Work out of the request](background.md)), then gives the file with its
results to a function of yours, to save them:

```elixir
Storehouse.analyze_later(file, [MyApp.Analyzers.Pages],
  then: {MyApp.Documents, :save_analysis, [document.id]}
)
```

With Ecto, `Storehouse.Ecto` saves them in the record's column: only the
file's analysis, on the row as it is then, so a caption a
person wrote meanwhile stays. A file replaced in the meantime is left as
it is.

```elixir
Storehouse.Ecto.update(Repo, changeset, analyze: [avatar: [MyApp.Analyzers.Colors]])

# or, for a record's files, whenever:
Storehouse.Ecto.analyze_later(Repo, user, :avatar, [MyApp.Analyzers.Colors])
```

`update/3` and `insert/3` analyze only the files the save put in the
field.

## Again, over files stored before

A step added a year in, a step that failed, files from before analysis
existed: `Storehouse.Ecto.reprocess/5` runs steps over the files of a
field in every record of a table, a batch at a time in the order of the
primary key, so a table of any size takes the memory of a batch:

```elixir
Storehouse.Ecto.reprocess(Repo, MyApp.Photo, :image, [Storehouse.Analyzer.Placeholder])
#=> {:ok, %{records: 10_000, files: 9_412, skipped: 588, failed: []}}
```

A file that has every step's result already is skipped, so it can be
stopped and run again, and does only what is missing; `force: true` runs
every one again. Each file is a job of the app's runner; `now: true` runs
them where it is called, and saves their results before it returns. From
the command line, with its progress:

```sh
mix storehouse.reprocess --repo MyApp.Repo --schema MyApp.Photo --field image \
  --step Storehouse.Analyzer.Placeholder --now
```

## A placeholder while a photograph loads

`Storehouse.Analyzer.Placeholder` makes what a page paints before a
photograph arrives: a tiny version of it, a few hundred bytes as a data
URI that the browser stretches into a soft blur, and its average colour.
It needs libvips, through Vix:

```elixir
# mix.exs
{:vix, "~> 0.31"}

Storehouse.store(upload.path, analyze: [Storehouse.Analyzer.Placeholder])

Storehouse.File.analyzed(file, :placeholder)
#=> %{"placeholder" => "data:image/webp;base64,UklGR…", "color" => "#9a7b76",
#     "width" => 16, "height" => 11}
```

It shrinks the photograph as libvips loads it, so a 6000 × 4000 JPEG
(18 MB) takes about 150 ms where decoding it whole takes 260, and a few
kilobytes of memory past what the decoder holds. It is turned as its EXIF
says, put in sRGB, and saved with none of the original's metadata: no
place, no camera, no colour profile. Its options say how large (`:size`,
16 pixels on the longest edge), in what (`:format`, `:webp`, `:jpeg` or
`:png`; `:quality`, 40), and on what colour a photograph with
transparency is laid (`:background`, `"#rrggbb"`); without it, WebP and
PNG keep the transparency.

A file libvips cannot read fails the step, with why, and the page shows
its colour of choice instead. Which formats it reads is libvips's: the
precompiled one Vix brings reads JPEG, PNG, WebP, TIFF, GIF and AVIF, not
HEIC; build Vix against your system's libvips for more.

In a page, under the photograph:

```heex
<img src={@photo.url} width={@photo.width} height={@photo.height} loading="lazy"
     style={"background: #{@photo.color} url(#{@photo.placeholder}) center / cover"} />
```

and in JSON, for a frontend, with `Storehouse.File.to_map(file, analysis:
[:placeholder])`. A step of your own, under its own name, takes its place
for anything else: a BlurHash or ThumbHash, made with the library you
choose.

## A step that changes the file

Analysis reads a file and leaves it as it is, with one exception you add
yourself: `Storehouse.Analyzer.EditMetadata` edits the metadata inside a
JPEG, PNG or WebP (`Storehouse.JPEG`, `Storehouse.PNG`, `Storehouse.WebP`)
and writes the file back over the original.
It is never run unless named, and it never re-encodes the image: the
pixels are the same ones, byte for byte. Only the metadata is read into
memory; the image data is copied from file to file, so a 50 MB photo
takes the memory of its metadata.

```elixir
steps = [
  # Before anything reads it: the steps after it read the edited file.
  {Storehouse.Analyzer.EditMetadata, strip: :gps, put: %{copyright: "© Ana Sousa"}},
  MyApp.Analyzers.Exif
]

Storehouse.store(upload.path, analyze: steps)
```

`strip: {:keep, [:orientation, :copyright]}` keeps only the tags named
and removes XMP, IPTC, comments and other text too. Other formats (HEIC,
AVIF, TIFF) are skipped, and a file that cannot be read fails the step and
is left as it was.

What makes the changes is a `Storehouse.MetadataEditor`. Storehouse's
own edits JPEG, PNG and WebP; for other types (HEIC, TIFF, a camera's raw files),
or another tool altogether, an editor of your app's takes its place, for
every step or for one, with no other change:

```elixir
config :storehouse, :metadata_editor, MyApp.ExifTool

{Storehouse.Analyzer.EditMetadata, strip: :gps, editor: MyApp.ExifTool}
```

The changes are the same whichever editor makes them, and
`Storehouse.MetadataEditor` shows one around ExifTool.

The file's `:checksum` stays the one of the upload, so `:existing` still
finds the same photo uploaded again. The step's result has the stored
file's own `"checksum"` and `"bytes"` now:

```elixir
Storehouse.File.analyzed(file, :edit_metadata)
#=> %{"changed" => true, "stripped" => "gps", "put" => ["copyright"],
#     "bytes" => 2_144, "checksum" => "q1…="}
```

## Kept through a deploy

The steps run in a job of the app's runner: with Oban, kept in the
database and tried again when the store fails, so a deploy in the middle
of them loses nothing. [Work out of the request](background.md) says how
the runner is chosen, and how to give its queue.

## Telemetry

Each step is a span, `[:storehouse, :analyze, ...]`, with the file's
`:key`, the `:step`, and how it went (`result: :ok | :skip | :error`).
