defmodule Storehouse.Job do
  @moduledoc """
  A piece of Storehouse's work done out of the request: a file's
  analysis, a deletion, a mirror's copy. A runner keeps it and runs it
  (`Storehouse.Runner`).

  A job is a worker, a module of this behaviour, and its arguments, a map
  JSON holds, so that any runner can keep it: in memory, in a database
  (Oban), in a workflow engine. `to_map/1` gives a job as JSON holds it,
  and `from_map/1` gives it back.

  A runner calls `run/1` until it gives `:ok`, at most `:max_attempts`
  times, then `discarded/3`.

  ## Telemetry

  Each run is a span, `[:storehouse, :job, :start | :stop | :exception]`,
  with the job's `:worker` and `:unique`, and `result: :ok | :error`;
  a job given up is `[:storehouse, :job, :discarded]`, with
  `%{attempts: n}` and the `:job` and the `:reason`.
  """

  require Logger

  @enforce_keys [:worker, :args, :unique]
  defstruct [:worker, :args, :unique, max_attempts: 10]

  @type t :: %__MODULE__{
          worker: module(),
          args: map(),
          unique: String.t(),
          max_attempts: pos_integer()
        }

  @doc "Does the job's work, with its arguments: `:ok`, or why it failed, to be tried again."
  @callback perform(args :: map()) :: :ok | {:error, term()}

  @doc """
  A job of `worker` with `args`, a map with string keys that JSON holds.

    * `:unique` - what makes two jobs one while one waits (a runner that
      can keeps one of them). The default is the worker and its arguments.
    * `:max_attempts` - how many times it is tried. The default is 10.
  """
  @spec new(module(), map(), keyword()) :: t()
  def new(worker, args, opts \\ []) when is_atom(worker) and is_map(args) do
    %__MODULE__{
      worker: worker,
      args: args,
      unique:
        Keyword.get_lazy(opts, :unique, fn -> "#{inspect(worker)}:#{:erlang.phash2(args)}" end),
      max_attempts: Keyword.get(opts, :max_attempts, 10)
    }
  end

  @doc """
  Runs the job once: `:ok`, or `{:error, reason}` for a runner to try it
  again. A worker that raises gives its message as the reason.
  """
  @spec run(t()) :: :ok | {:error, term()}
  def run(%__MODULE__{worker: worker, args: args} = job) do
    meta = %{worker: worker, unique: job.unique}

    :telemetry.span([:storehouse, :job], meta, fn ->
      result = safely(worker, args)
      {result, Map.put(meta, :result, if(result == :ok, do: :ok, else: :error))}
    end)
  end

  defp safely(worker, args) do
    case worker.perform(args) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Tells that a runner gave the job up after `attempts`: a warning in the
  log, and the event `[:storehouse, :job, :discarded]`.
  """
  @spec discarded(t(), term(), pos_integer()) :: :ok
  def discarded(%__MODULE__{} = job, reason, attempts) do
    Logger.warning(
      "Storehouse: gave up #{inspect(job.worker)} #{inspect(job.args)} after #{attempts} attempts: #{inspect(reason)}"
    )

    :telemetry.execute([:storehouse, :job, :discarded], %{attempts: attempts}, %{
      job: job,
      reason: reason
    })
  end

  @doc "The job as JSON holds it, for a runner that keeps it out of memory."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = job) do
    %{
      "worker" => inspect(job.worker),
      "args" => job.args,
      "unique" => job.unique,
      "max_attempts" => job.max_attempts
    }
  end

  @doc """
  The job of a map `to_map/1` gave, or `{:error, {:not_a_worker, name}}`
  when its worker is not a module of this behaviour, in this app.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"worker" => name, "args" => args} = map) when is_binary(name) and is_map(args) do
    with {:ok, worker} <- existing(name),
         true <- worker?(worker) || {:error, {:not_a_worker, name}} do
      {:ok,
       %__MODULE__{
         worker: worker,
         args: args,
         unique: Map.get(map, "unique", name),
         max_attempts: Map.get(map, "max_attempts", 10)
       }}
    end
  end

  def from_map(map), do: {:error, {:not_a_job, map}}

  @doc false
  # A module named in a job's arguments (a worker, a store), only one
  # this app has: a name never makes an atom.
  @spec module(String.t()) :: {:ok, module()} | {:error, term()}
  def module(name) when is_binary(name), do: existing(name)

  defp existing(name) do
    module = Module.safe_concat([name])
    if Code.ensure_loaded?(module), do: {:ok, module}, else: {:error, {:no_module, name}}
  rescue
    ArgumentError -> {:error, {:no_module, name}}
  end

  defp worker?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    __MODULE__ in behaviours
  end
end
