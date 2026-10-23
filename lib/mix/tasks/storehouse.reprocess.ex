defmodule Mix.Tasks.Storehouse.Reprocess do
  @shortdoc "Runs analysis steps over the files of a table's records"

  @moduledoc """
  Runs analysis steps over the files of a field in every record of a
  schema (`Storehouse.Ecto.reprocess/5`), with its progress: a step added
  after files were stored, files from before analysis existed.

      mix storehouse.reprocess --repo MyApp.Repo --schema MyApp.Photo --field image \\
        --step MyApp.Analyzers.Placeholder

  Files that have every step's result already are skipped, so it can be
  stopped and run again: it does only what is missing. Each batch prints
  the primary key it got to, which `--after` starts after.

  ## Options

    * `--repo`, `--schema`, `--field` - the records and their field of
      files.
    * `--step` - an analysis step, by module; once for each. For a step
      with options, call `Storehouse.Ecto.reprocess/5` from a script.
    * `--now` - run the steps here, and save their results before it ends;
      the default gives each file to the app's runner, as a job.
    * `--force` - run every file's steps again.
    * `--batch-size` - records read at a time. The default is 500.
    * `--concurrency` - with `--now`, files at once. The default is 4.
    * `--after` - the primary key to start after.
  """

  use Mix.Task

  # Storehouse.Ecto is there when the app has Ecto.
  @compile {:no_warn_undefined, Storehouse.Ecto}

  @requirements ["app.start"]
  @switches [
    repo: :string,
    schema: :string,
    field: :string,
    step: :keep,
    now: :boolean,
    force: :boolean,
    batch_size: :integer,
    concurrency: :integer,
    after: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)
    repo = module!(opts, :repo)
    schema = module!(opts, :schema)

    field =
      String.to_existing_atom(opts[:field] || Mix.raise("Give the field of files: --field image"))

    steps = for {:step, step} <- opts, do: module!([step: step], :step)
    if steps == [], do: Mix.raise("Give a step at least: --step MyApp.Analyzers.Placeholder")

    reprocess_opts =
      [
        now: Keyword.get(opts, :now, false),
        force: Keyword.get(opts, :force, false),
        batch_size: Keyword.get(opts, :batch_size, 500),
        max_concurrency: Keyword.get(opts, :concurrency, 4),
        on_progress: &progress/1
      ] ++ if(last = opts[:after], do: [after: primary_key(last)], else: [])

    {:ok, summary} = Storehouse.Ecto.reprocess(repo, schema, field, steps, reprocess_opts)

    Mix.shell().info(
      "#{summary.records} records: #{summary.files} files #{if opts[:now], do: "analyzed", else: "given to the runner"}, #{summary.skipped} done already, #{length(summary.failed)} failed."
    )

    for {id, key, reason} <- summary.failed,
        do: Mix.shell().error("#{inspect(id)} #{key}: #{inspect(reason)}")

    if summary.failed != [], do: exit({:shutdown, 1})
  end

  defp progress(summary),
    do:
      Mix.shell().info(
        "#{summary.records} records, #{summary.files} files… (after #{inspect(summary.last)})"
      )

  # An integer key, or another (a UUID) as it is.
  defp primary_key(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _other -> text
    end
  end

  defp module!(opts, option) do
    name = opts[option] || Mix.raise("Give --#{option}, a module: --#{option} MyApp.…")
    module = Module.concat([name])

    if Code.ensure_loaded?(module),
      do: module,
      else: Mix.raise("No module #{name} for --#{option}")
  end
end
