defmodule Storehouse.Cleaner do
  @moduledoc """
  Deletes files later, and again until the store answers
  (`Storehouse.delete_later/2`, `Storehouse.delete_prefix_later/2`), and
  sweeps the temporary files of forms never saved: a process of the app's
  own, with no job queue and no cron.

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {Storehouse.Cleaner, sweep: [max_age: 86_400]},
        MyAppWeb.Endpoint
      ]

  ## Deleting later

  A deletion queued with `Storehouse.delete_later/2` runs at once, beside
  the app's requests; when the store fails, it runs again after a while
  (one second, then twice as long each time, up to five minutes), up to
  `:max_attempts` times. Then it is given up, with a warning in the log
  and the event `[:storehouse, :cleaner, :discarded]`. The queue lives in
  this process: deletions not done yet when the app stops are not done.
  Give a bucket a lifecycle rule, or use Oban, for deletions that must
  outlive a deploy.

  ## Sweeping

  With `:sweep`, the files under the temporary prefix
  (`Storehouse.cache_prefix/0`) older than `:max_age` are deleted every
  `:every` seconds: the uploads of forms never saved, on a store with no
  lifecycle rule (the local disk, MinIO). On several nodes, each sweep runs
  on one of them at a time.

  ## Options

    * `:max_attempts` - how many times a deletion is tried. The default
      is 10.
    * `:max_concurrency` - how many deletions run at once. The default
      is 4.
    * `:sweep` - sweeping, a keyword list: `:max_age` (in seconds; the
      default is a day), `:every` (in seconds; the default is an hour),
      `:prefix` (the default is `Storehouse.cache_prefix/0`) and
      `:adapter`. The default is no sweeping.
    * `:backoff` - a function of the attempt that failed (1, 2, …) that
      gives the wait before the next, in milliseconds.
  """

  use GenServer

  require Logger

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  @doc "Starts the cleaner, registered as `Storehouse.Cleaner`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :sweep,
        :backoff,
        max_attempts: 10,
        max_concurrency: 4,
        name: __MODULE__
      ])

    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc false
  # A deletion, queued in the cleaner when it runs, done at once when it does not.
  def queue({_kind, _target} = target, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    server = Keyword.get(opts, :cleaner, __MODULE__)

    if GenServer.whereis(server) do
      GenServer.cast(server, {:queue, target, adapter})
    else
      case run(target, adapter) do
        {:ok, _count} -> :ok
        result -> result
      end
    end
  end

  @doc """
  Deletes the files under the temporary prefix that are older than
  `:max_age` seconds, at once: what the cleaner's `:sweep` does on its
  own, for a task or a job of the app's. Gives `{:ok, count}`.

  Takes `:max_age` (the default is a day), `:prefix` (the default is
  `Storehouse.cache_prefix/0`) and `:adapter`.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    prefix = Keyword.get_lazy(opts, :prefix, &Storehouse.cache_prefix/0)
    before = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :max_age, 86_400))

    :telemetry.span([:storehouse, :sweep], %{prefix: prefix, adapter: adapter}, fn ->
      result =
        with {:ok, entries} <- Storehouse.list(prefix, adapter: adapter) do
          entries
          |> Stream.filter(&(DateTime.compare(&1.modified_at, before) == :lt))
          |> Stream.map(& &1.key)
          |> Storehouse.delete_keys(adapter)
        end

      {result, %{prefix: prefix, adapter: adapter, result: result}}
    end)
  end

  @impl GenServer
  def init(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()

    state = %{
      tasks: tasks,
      max_attempts: opts[:max_attempts],
      max_concurrency: opts[:max_concurrency],
      backoff: opts[:backoff] || (&backoff/1),
      sweep: sweep_opts(opts[:sweep]),
      waiting: :queue.new(),
      running: %{}
    }

    if state.sweep, do: send(self(), :sweep)
    {:ok, state}
  end

  defp sweep_opts(nil), do: nil

  defp sweep_opts(opts),
    do: Keyword.validate!(opts, [:prefix, :adapter, max_age: 86_400, every: 3_600])

  @impl GenServer
  def handle_cast({:queue, target, adapter}, state),
    do: {:noreply, next(enqueue(state, %{target: target, adapter: adapter, attempt: 1}))}

  @impl GenServer
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, :timer.seconds(state.sweep[:every]))
    {:noreply, next(enqueue(state, %{target: :sweep, adapter: nil, attempt: 1}))}
  end

  def handle_info({:retry, job}, state), do: {:noreply, next(enqueue(state, job))}

  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {job, running} = Map.pop(state.running, ref)
    {:noreply, next(finished(%{state | running: running}, job, result))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {job, running} = Map.pop(state.running, ref)
    {:noreply, next(finished(%{state | running: running}, job, {:error, {:exit, reason}}))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(state, job), do: %{state | waiting: :queue.in(job, state.waiting)}

  # The deletions waiting, started while fewer than max_concurrency run.
  defp next(state) do
    with true <- map_size(state.running) < state.max_concurrency,
         {{:value, job}, waiting} <- :queue.out(state.waiting) do
      task = Task.Supervisor.async_nolink(state.tasks, fn -> work(job, state.sweep) end)
      next(%{state | waiting: waiting, running: Map.put(state.running, task.ref, job)})
    else
      _full_or_empty -> state
    end
  end

  # A sweep runs on one node at a time: on another, it is skipped.
  defp work(%{target: :sweep}, sweep) do
    # The lock's requester is this task: another node's is another.
    lock = {{__MODULE__, :sweep}, self()}

    case :global.trans(lock, fn -> sweep(sweep) end, [node() | Node.list()], 0) do
      :aborted -> :ok
      result -> result
    end
  end

  defp work(%{target: target, adapter: adapter}, _sweep), do: run(target, adapter)

  defp run({:key, key}, adapter), do: Storehouse.delete(key, adapter: adapter)
  defp run({:prefix, prefix}, adapter), do: Storehouse.delete_prefix(prefix, adapter: adapter)

  defp finished(state, _job, :ok), do: state
  defp finished(state, _job, {:ok, _count}), do: state

  # A sweep that failed waits for the next.
  defp finished(state, %{target: :sweep}, {:error, reason}) do
    Logger.warning("Storehouse.Cleaner: the sweep failed: #{inspect(reason)}")
    state
  end

  defp finished(state, %{attempt: attempt} = job, {:error, reason}) do
    if attempt < state.max_attempts do
      Process.send_after(self(), {:retry, %{job | attempt: attempt + 1}}, state.backoff.(attempt))
    else
      Logger.warning(
        "Storehouse.Cleaner: gave up deleting #{inspect(job.target)} after #{attempt} attempts: #{inspect(reason)}"
      )

      :telemetry.execute([:storehouse, :cleaner, :discarded], %{attempts: attempt}, %{
        target: job.target,
        adapter: job.adapter,
        reason: reason
      })
    end

    state
  end

  defp backoff(attempt), do: min(1_000 * Integer.pow(2, attempt - 1), 300_000)
end
