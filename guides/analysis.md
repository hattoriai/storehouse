# After the upload

Once a file is stored, an app often wants to know more of it than its
type and size: an image's EXIF, its main colours, a PDF's pages, a
video's length. Each is a step, an analyzer of your own or Storehouse's
(`Storehouse.Analyzer`), and its result is kept in the file's metadata
under `"analyzed"`. Nothing runs unless you name the steps.

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
(`force: true` runs it again). A step that fails, or raises, keeps why
(`%{"error" => …}`) and leaves the others' results; the next run tries it
again. `:skip` is kept as `%{"skipped" => true}`.

## Later, and saved

Most analysis should not hold up a request. `Storehouse.analyze_later/3`
runs it in a process of the app's, then gives the file with its results to
a function of yours, to save them:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Storehouse.Tasks, max_children: 4},
  MyAppWeb.Endpoint
]
```

```elixir
Storehouse.analyze_later(file, [MyApp.Analyzers.Pages],
  then: {MyApp.Documents, :save_analysis, [document.id]}
)
```

With Ecto, `Storehouse.Ecto` saves them in the record's column: only the
file's `"analyzed"` metadata, on the row as it is then, so a caption a
person wrote meanwhile stays. A file replaced in the meantime is left as
it is.

```elixir
Storehouse.Ecto.update(Repo, changeset, analyze: [avatar: [MyApp.Analyzers.Colors]])

# or, for a record's files, whenever:
Storehouse.Ecto.analyze_later(Repo, user, :avatar, [MyApp.Analyzers.Colors])
```

`update/3` and `insert/3` analyze only the files the save put in the
field.

## With Oban

`Storehouse.Tasks` keeps its work in memory: a deploy in the middle of it
loses it. With Oban in the app, `runner: :oban` runs the steps in a job
(`Storehouse.Oban.Analyze`, on the `:storehouse` queue), retried when the
store fails:

```elixir
config :my_app, Oban, queues: [default: 10, storehouse: 4]

Storehouse.Ecto.analyze_later(Repo, user, :avatar, steps, runner: :oban)
```

## Telemetry

Each step is a span, `[:storehouse, :analyze, ...]`, with the file's
`:key`, the `:step`, and how it went (`result: :ok | :skip | :error`).
