defmodule Mix.Tasks.Storehouse.Copy do
  @shortdoc "Copies the files of one store to another"

  @moduledoc """
  Copies the files of one store to another (`Storehouse.copy_prefix/2`),
  with its progress: to move to another provider, fill a mirror
  (`Storehouse.Mirror`), or bring a production account's files into
  development.

      mix storehouse.copy --from MyApp.OldMedia --to MyApp.Media
      mix storehouse.copy --from MyApp.Media --to MyApp.DevMedia --prefix accounts/42/

  Files the destination has already are skipped, so it can be stopped and
  run again: it copies only what is missing.

  ## Options

    * `--from` and `--to` - the stores, by module.
    * `--prefix` - the keys to copy, by their start. The default is every
      file.
    * `--concurrency` - how many files are copied at once. The default
      is 4.
    * `--verify` - read both copies of a file to compare them, where the
      stores keep no checksum to compare (`Storehouse.copy/2`).
  """

  use Mix.Task

  @requirements ["app.start"]
  @switches [from: :string, to: :string, prefix: :string, concurrency: :integer, verify: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)
    from = store!(opts, :from)
    to = store!(opts, :to)
    prefix = Keyword.get(opts, :prefix, "")
    counter = :counters.new(1, [])

    Mix.shell().info(
      "Copying #{if prefix == "", do: "every file", else: prefix} from #{inspect(from)} to #{inspect(to)}"
    )

    progress = &progress(counter, &1, &2)

    copy_opts = [
      from: from,
      to: to,
      verify: Keyword.get(opts, :verify, false),
      max_concurrency: Keyword.get(opts, :concurrency, 4),
      on_progress: progress
    ]

    case Storehouse.copy_prefix(prefix, copy_opts) do
      {:ok, %{copied: copied, skipped: skipped, failed: failed}} ->
        Mix.shell().info(
          "Copied #{copied}, skipped #{skipped} already there, #{length(failed)} failed."
        )

        if failed != [], do: exit({:shutdown, 1})

      {:error, reason} ->
        Mix.raise("Could not copy: #{inspect(reason)}")
    end
  end

  # Each failure as it comes, and a count every hundred files.
  defp progress(counter, key, result) do
    :counters.add(counter, 1, 1)
    done = :counters.get(counter, 1)

    case result do
      {:error, reason} -> Mix.shell().error("#{key}: #{inspect(reason)}")
      _copied_or_skipped -> if rem(done, 100) == 0, do: Mix.shell().info("#{done} files…")
    end
  end

  defp store!(opts, option) do
    name = opts[option] || Mix.raise("Give the store to copy #{option}: --#{option} MyApp.Media")
    store = Module.concat([name])

    if Code.ensure_loaded?(store),
      do: store,
      else: Mix.raise("No store #{name}: --#{option} names a module, as MyApp.Media")
  end
end
