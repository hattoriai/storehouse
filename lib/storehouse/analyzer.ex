defmodule Storehouse.Analyzer do
  @moduledoc """
  Work on a file after it is stored: what it is read for (an image's EXIF,
  a placeholder, a video's length, a PDF's pages), each step an analyzer,
  what it made of the file kept in the file's `:analysis`, by its name, as
  a `Storehouse.Analysis`: its status, its result, why it failed.

      defmodule MyApp.Analyzers.Pages do
        @behaviour Storehouse.Analyzer

        @impl true
        def analyze(%Storehouse.File{content_type: "application/pdf"}, path, _opts) do
          {output, 0} = System.cmd("pdfinfo", [path])
          [_, pages] = Regex.run(~r/Pages:\\s+(\\d+)/, output)
          {:ok, %{"pages" => String.to_integer(pages)}}
        end

        def analyze(_file, _path, _opts), do: :skip
      end

      {:ok, file} = Storehouse.analyze(file, [MyApp.Analyzers.Pages])
      Storehouse.File.analyzed(file, MyApp.Analyzers.Pages.name())
      #=> %{"pages" => 12}

  ## Steps

  A step is an analyzer's module, or `{module, opts}`. They run in their
  order, and each is run once: a step whose result the file has already
  is skipped (`force: true` runs it again). A step that fails leaves the
  others' results, and its own analysis is `:failed`, with why; the next
  run tries it again. `:skip` means the step does not apply to the file,
  and its analysis is `:skipped`.

  The file is read from the store once for all the steps that need it
  (`c:needs_file?/0`), to a temporary file, and that file is removed
  after them. A file just stored from a path (`Storehouse.store/2` with
  `:analyze`) is read from that path, with no download.

  ## Later

  `Storehouse.analyze_later/3` runs them out of the request, as a job of
  the app's runner (`Storehouse.Runner`: Oban's, a process of the app's,
  or one of its own); then the app's `:then` function gets the file with
  its results, to save them. `Storehouse.Ecto.analyze_later/5` saves them
  in the record's column.

  ## Telemetry

  Each step is a span, `[:storehouse, :analyze, ...]`, with the `:key` and
  the `:step`, and `result: :ok | :skip | :error` (with the `:reason`).
  """

  @typedoc "A step: an analyzer's module, or the module and its options."
  @type step :: module() | {module(), keyword()}

  @doc """
  Reads what the step reads from the file, at `path` on the local disk (or
  `nil`, for a step that does not need the file: `c:needs_file?/0`).
  `opts` are the step's, with the store as `:adapter`.
  `{:ok, result}` is kept as the step's result, a map JSON can hold
  (`Storehouse.Metadata`); `:skip` when the step does not apply to the
  file.

  A step that changes the stored file (`Storehouse.Analyzer.EditMetadata`)
  gives `{:ok, result, path}`, with the file as it is now at `path`, a
  temporary file of its own: the steps after it read that one, and it is
  removed after them.
  """
  @callback analyze(Storehouse.File.t(), path :: Path.t() | nil, opts :: keyword()) ::
              {:ok, map()} | {:ok, map(), Path.t()} | :skip | {:error, term()}

  @doc """
  The name the step's result is kept under. Optional: the default is the
  module's last part, in snake case (`MyApp.Analyzers.Pages` → `"pages"`).
  """
  @callback name() :: String.t()

  @doc "Whether the step reads the file's bytes. Optional: the default is `true`."
  @callback needs_file?() :: boolean()

  @optional_callbacks name: 0, needs_file?: 0

  @doc "The name a step's result is kept under (`c:name/0`)."
  @spec name(step()) :: String.t()
  def name({module, _opts}), do: name(module)

  def name(module) when is_atom(module) do
    if exported?(module, :name, 0),
      do: module.name(),
      else: module |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp exported?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  @doc false
  # The steps of a file, run in order: `{:ok, file, names}` with each one's
  # analysis and the names of those that ran, or `{:error, reason}` when
  # the file could not be read for them.
  @spec run(Storehouse.File.t(), [step()], keyword()) ::
          {:ok, Storehouse.File.t(), [String.t()]} | {:error, term()}
  def run(%Storehouse.File{} = file, steps, opts) do
    force = Keyword.get(opts, :force, false)
    steps = steps |> Enum.map(&normalize/1) |> Enum.filter(&(force or not done?(file, &1)))

    # Each step is given the store, to read what it needs itself.
    steps =
      for {module, step_opts} <- steps,
          do: {module, Keyword.put_new(step_opts, :adapter, opts[:adapter])}

    with_source(file, steps, opts, fn path ->
      {:ok, run_steps(file, steps, path, opts), Enum.map(steps, &name/1)}
    end)
  end

  # Each step reads the file from where the step before left it; the
  # files steps left are removed after them.
  defp run_steps(file, steps, path, opts) do
    {file, _path, left} =
      Enum.reduce(steps, {file, path, []}, fn step, {file, path, left} ->
        case run_step(file, step, path, opts) do
          {file, ^path} -> {file, path, left}
          {file, changed} -> {file, changed, [changed | left]}
        end
      end)

    Enum.each(left, &File.rm/1)
    file
  end

  defp normalize({module, step_opts}) when is_atom(module) and is_list(step_opts),
    do: {module, step_opts}

  defp normalize(module) when is_atom(module), do: {module, []}

  # Done: ran, and either read the file or found it is not one for it.
  defp done?(file, step) do
    case Storehouse.File.analysis(file, name(step)) do
      %Storehouse.Analysis{status: status} -> status in [:ok, :skipped]
      nil -> false
    end
  end

  defp needs_file?({module, _opts}),
    do: not exported?(module, :needs_file?, 0) or module.needs_file?()

  # The file, on the local disk, for the steps that need it: the path it
  # was stored from, or a download removed after the steps.
  defp with_source(file, steps, opts, fun) do
    cond do
      not Enum.any?(steps, &needs_file?/1) ->
        fun.(nil)

      path = opts[:path] ->
        fun.(path)

      true ->
        path =
          Path.join(System.tmp_dir!(), "storehouse-analyze-#{System.unique_integer([:positive])}")

        try do
          with :ok <- Storehouse.download(file, path, Keyword.take(opts, [:adapter, :max_bytes])),
               do: fun.(path)
        after
          File.rm(path)
        end
    end
  end

  # The file with the step's analysis, and the path the next steps read
  # it from: a new one when the step changed it.
  defp run_step(file, {module, step_opts} = step, path, opts) do
    name = name(step)
    meta = %{key: file.key, step: name}
    given = if needs_file?(step), do: path

    :telemetry.span([:storehouse, :analyze], meta, fn ->
      {result, file, changed} =
        case safely(module, file, given, step_opts) do
          {:ok, result, changed} when is_binary(changed) ->
            {result, file} = keep(file, name, {:ok, result})
            {result, file, changed}

          result ->
            {result, file} = keep(file, name, result)
            {result, file, path}
        end

      with {:error, reason} <- result,
           do: Storehouse.Notify.notify(:failed, %{file: file, step: name, reason: reason}, opts)

      {{file, changed}, Map.merge(meta, outcome(result))}
    end)
  end

  defp safely(module, file, path, opts) do
    module.analyze(file, path, opts)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # The step's analysis in the file: its result, as JSON holds it, else
  # a failure.
  defp keep(file, name, {:ok, result}) when is_map(result) do
    case Storehouse.Metadata.normalize(result) do
      {:ok, result} ->
        {:ok, Storehouse.File.put_analysis(file, name, Storehouse.Analysis.ok(result))}

      {:error, reason} ->
        keep(file, name, {:error, reason})
    end
  end

  defp keep(file, name, :skip),
    do: {:skip, Storehouse.File.put_analysis(file, name, Storehouse.Analysis.skipped())}

  defp keep(file, name, {:error, reason}),
    do:
      {{:error, reason},
       Storehouse.File.put_analysis(file, name, Storehouse.Analysis.failed(reason))}

  defp keep(file, name, other), do: keep(file, name, {:error, {:invalid_result, other}})

  defp outcome({:error, reason}), do: %{result: :error, reason: reason}
  defp outcome(result), do: %{result: result}
end
