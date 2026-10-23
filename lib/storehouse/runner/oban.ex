if Code.ensure_loaded?(Oban.Worker) do
  defmodule Storehouse.Runner.Oban.Worker do
    @moduledoc """
    The Oban worker of `Storehouse.Runner.Oban`: a job's map
    (`Storehouse.Job.to_map/1`) as its arguments, run with
    `Storehouse.Job.run/1`, retried by Oban when it fails.
    """

    use Oban.Worker,
      queue: :storehouse,
      max_attempts: 10,
      unique: [keys: [:unique], states: [:available, :scheduled, :retryable]]

    alias Storehouse.Job

    @impl Oban.Worker
    def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
      case Job.from_map(args) do
        {:ok, job} -> ran(job, Job.run(job), attempt, max)
        # A job whose worker this app no longer has is not tried again.
        {:error, reason} -> {:cancel, reason}
      end
    end

    defp ran(_job, :ok, _attempt, _max), do: :ok

    defp ran(job, {:error, reason} = error, attempt, max) do
      if attempt >= max, do: Job.discarded(job, reason, attempt)
      error
    end
  end
end

defmodule Storehouse.Runner.Oban do
  @moduledoc """
  A runner (`Storehouse.Runner`) in Oban: each job an Oban job
  (`Storehouse.Runner.Oban.Worker`), kept in the app's database, so it
  outlives a deploy, and retried with Oban's backoff, up to the job's
  `:max_attempts`. A job waiting is not inserted twice (Oban's `unique`).

  The default runner when the app runs an Oban instance named `Oban`.

  ## The queue, and the instance

  Its jobs go on the queue the app names, in its config, whether this
  runner is the default or named:

      config :storehouse, Storehouse.Runner.Oban, queue: :media, name: MyApp.Oban

      config :my_app, Oban, queues: [default: 10, media: 4]

  With no `:queue`, they go on `:storehouse`. A queue the instance does
  not run is told once in the log: its jobs would wait.

  ## Options

  In `config :storehouse, Storehouse.Runner.Oban`, or as the runner's own
  (`{Storehouse.Runner.Oban, queue: :media}`), which take their place:

    * `:name` - the Oban instance. The default is `Oban`.
    * `:queue` - the default is `:storehouse`.
    * `:max_attempts` - in place of each job's own.
    * Any other option of `Oban.Job.new/2` (`:priority`, `:tags`).
  """

  @behaviour Storehouse.Runner

  require Logger

  alias Storehouse.Runner.Oban.Worker

  # Oban is optional: this is called only with Oban there.
  @compile {:no_warn_undefined, [Oban, Worker]}

  @impl Storehouse.Runner
  def enqueue(%Storehouse.Job{} = job, opts) do
    opts = Keyword.merge(Application.get_env(:storehouse, __MODULE__, []), opts)
    {name, opts} = Keyword.pop(opts, :name, Oban)
    queue = Keyword.get(opts, :queue, :storehouse)
    warn_once(name, queue)

    changeset =
      job
      |> Storehouse.Job.to_map()
      |> Worker.new(Keyword.merge([queue: queue, max_attempts: job.max_attempts], opts))

    case Oban.insert(name, changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A queue the instance does not run: its jobs would wait, told once. In
  # Oban's testing modes no queue runs, and none is told.
  defp warn_once(name, queue) do
    key = {__MODULE__, name, queue}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      if running?(name) and not queue?(name, queue), do: warn(name, queue)
    end
  end

  defp running?(name) do
    Oban.config(name).testing == :disabled
  catch
    _kind, _reason -> false
  end

  defp queue?(name, queue) do
    Oban.check_queue(name, queue: queue) != nil
  catch
    :exit, _reason -> false
  end

  defp warn(name, queue) do
    Logger.warning(
      "Storehouse.Runner.Oban: #{inspect(name)} runs no #{inspect(queue)} queue: Storehouse's jobs wait there. Add it to the Oban config, or give the runner another :queue."
    )
  end
end
