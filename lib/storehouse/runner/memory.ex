defmodule Storehouse.Runner.Memory do
  @moduledoc """
  A runner (`Storehouse.Runner`) in a process of the app's: each job run
  beside the app's requests, and when it fails, again after a while (a
  second, then twice as long each time, up to five minutes), up to its
  `:max_attempts`. Then it is given up (`Storehouse.Job.discarded/3`).

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {Storehouse.Runner.Memory, max_concurrency: 8},
        MyAppWeb.Endpoint
      ]

  Its jobs live in this process: those not done when the app stops are
  not done. `Storehouse.Runner.Oban` keeps them in the database.

  Without the process, a job runs at once, in the caller, and once.

  A job runs with the processes of the caller that gave it as its
  `$callers`, so it sees what they own: a test's files in
  `Storehouse.Memory`.

  ## Options

    * `:max_concurrency` - how many jobs run at once. The default is 4.
    * `:max_attempts` - how many times a job is tried, in place of each
      job's own (10).
    * `:backoff` - a function of the attempt that failed (1, 2, …) that
      gives the wait before the next, in milliseconds.
    * `:name` - the default is `Storehouse.Runner.Memory`; a job's runner
      `{Storehouse.Runner.Memory, name: …}` names another.
  """

  use GenServer

  @behaviour Storehouse.Runner

  alias Storehouse.Job

  @doc false
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the runner, registered as `Storehouse.Runner.Memory` (or its `:name`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [:backoff, :max_attempts, max_concurrency: 4, name: __MODULE__])

    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl Storehouse.Runner
  def enqueue(%Job{} = job, opts) do
    server = Keyword.get(opts, :name, __MODULE__)
    callers = [self() | Process.get(:"$callers", [])]

    if GenServer.whereis(server) do
      GenServer.cast(server, {:enqueue, job, callers})
    else
      Job.run(job)
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok,
     %{
       tasks: tasks,
       max_attempts: opts[:max_attempts],
       max_concurrency: opts[:max_concurrency],
       backoff: opts[:backoff] || (&backoff/1),
       waiting: :queue.new(),
       running: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:enqueue, job, callers}, state),
    do: {:noreply, next(queued(state, %{job: job, callers: callers, attempt: 1}))}

  @impl GenServer
  def handle_info({:retry, entry}, state), do: {:noreply, next(queued(state, entry))}

  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {entry, running} = Map.pop(state.running, ref)
    {:noreply, next(finished(%{state | running: running}, entry, result))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {entry, running} = Map.pop(state.running, ref)
    {:noreply, next(finished(%{state | running: running}, entry, {:error, reason}))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp queued(state, entry), do: %{state | waiting: :queue.in(entry, state.waiting)}

  # The jobs waiting, started while fewer than :max_concurrency run.
  defp next(state) do
    with true <- map_size(state.running) < state.max_concurrency,
         {{:value, entry}, waiting} <- :queue.out(state.waiting) do
      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          Process.put(:"$callers", entry.callers)
          Job.run(entry.job)
        end)

      next(%{state | waiting: waiting, running: Map.put(state.running, task.ref, entry)})
    else
      _full_or_empty -> state
    end
  end

  defp finished(state, _entry, :ok), do: state

  defp finished(state, %{job: job, attempt: attempt} = entry, {:error, reason}) do
    if attempt < (state.max_attempts || job.max_attempts) do
      Process.send_after(
        self(),
        {:retry, %{entry | attempt: attempt + 1}},
        state.backoff.(attempt)
      )
    else
      Job.discarded(job, reason, attempt)
    end

    state
  end

  defp backoff(attempt), do: min(1_000 * Integer.pow(2, attempt - 1), 300_000)
end
