defmodule Storehouse.Runner do
  @moduledoc """
  What keeps and runs Storehouse's work out of the request
  (`Storehouse.Job`): files analyzed later (`Storehouse.analyze_later/3`),
  deleted later (`Storehouse.delete_later/2`), copied to a mirror
  (`Storehouse.Mirror`). One runner does all of it, and another takes its
  place with no other change.

    * `Storehouse.Runner.Oban` - in Oban jobs, kept in the app's database:
      work that outlives a deploy. The default when the app runs Oban (an
      instance named `Oban`).
    * `Storehouse.Runner.Memory` - in a process of the app's, tried again
      with backoff; lost when the app stops. The default otherwise.
    * A module of the app's, of this behaviour: another job system, a
      workflow engine (Temporal and the like), a queue.

  ## Choosing it

      # For all of Storehouse's work:
      config :storehouse, runner: Storehouse.Runner.Oban

      # Oban's queue and instance, whether its runner is the default or named:
      config :storehouse, Storehouse.Runner.Oban, queue: :media, name: MyApp.Oban

      # For one call:
      Storehouse.analyze_later(file, steps, then: …, runner: Storehouse.Runner.Memory)

  A runner is a module, `{module, opts}`, or `:oban` and `:memory` for
  Storehouse's.

  ## Writing one

  A runner keeps the job (`Storehouse.Job.to_map/1` gives it as JSON
  holds it), and runs it with `Storehouse.Job.run/1` until it gives
  `:ok`, at most its `:max_attempts` times, then calls
  `Storehouse.Job.discarded/3`:

      defmodule MyApp.QueueRunner do
        @behaviour Storehouse.Runner

        @impl true
        def enqueue(job, _opts), do: MyApp.Queue.push("storehouse", Storehouse.Job.to_map(job))

        # Where MyApp.Queue delivers it:
        def handle(map, attempt) do
          {:ok, job} = Storehouse.Job.from_map(map)

          case Storehouse.Job.run(job) do
            :ok -> :ok
            {:error, reason} when attempt >= job.max_attempts -> Storehouse.Job.discarded(job, reason, attempt)
            {:error, reason} -> {:retry, reason}
          end
        end
      end
  """

  # Oban is optional: it is asked only when it is there.
  @compile {:no_warn_undefined, Oban}

  @doc """
  Keeps the job and runs it, out of the caller: `:ok` once it is kept,
  or `{:error, reason}` when it cannot be.
  """
  @callback enqueue(Storehouse.Job.t(), opts :: keyword()) :: :ok | {:error, term()}

  @typedoc "A runner: a module, `{module, opts}`, or `:oban` or `:memory`."
  @type t :: module() | {module(), keyword()} | :oban | :memory

  @doc false
  # The job given to the runner of `opts[:runner]`, else the app's config,
  # else the default.
  @spec enqueue(Storehouse.Job.t(), keyword()) :: :ok | {:error, term()}
  def enqueue(%Storehouse.Job{} = job, opts) do
    {runner, runner_opts} = resolve(opts[:runner])
    runner.enqueue(job, runner_opts)
  end

  @doc """
  The runner used, as `{module, opts}`: the one given (a module,
  `{module, opts}`, `:oban` or `:memory`), else `config :storehouse,
  :runner`, else Oban's when an instance named `Oban` runs, else
  `Storehouse.Runner.Memory`.
  """
  @spec resolve(t() | nil) :: {module(), keyword()}
  def resolve(nil) do
    case Application.get_env(:storehouse, :runner) do
      nil -> default()
      runner -> resolve(runner)
    end
  end

  def resolve(:oban), do: {Storehouse.Runner.Oban, []}
  def resolve(:memory), do: {Storehouse.Runner.Memory, []}
  def resolve({runner, opts}) when is_atom(runner) and is_list(opts), do: {runner, opts}
  def resolve(runner) when is_atom(runner), do: {runner, []}

  defp default do
    if Code.ensure_loaded?(Oban) and is_pid(Oban.whereis(Oban)),
      do: {Storehouse.Runner.Oban, []},
      else: {Storehouse.Runner.Memory, []}
  end
end
