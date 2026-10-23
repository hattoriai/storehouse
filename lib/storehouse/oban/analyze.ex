if Code.ensure_loaded?(Oban.Worker) do
  defmodule Storehouse.Oban.Analyze do
    @moduledoc """
    The Oban worker of `Storehouse.analyze_later/3` with `runner: :oban`:
    the steps of a file, run in a job that outlives a deploy, retried when
    the store fails, then the app's `:then` function with the file.

    Its queue is `:storehouse` (give it in the app's Oban config, or
    `oban: [queue: …]`). A job is unique per file and steps while it waits.
    Its arguments hold the file, the steps and the function as an Erlang
    term, which only the app writes.
    """

    use Oban.Worker,
      queue: :storehouse,
      max_attempts: 5,
      unique: [keys: [:key, :steps], states: [:available, :scheduled, :retryable]]

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"term" => term}}) do
      {file, steps, opts} = term |> Base.decode64!() |> :erlang.binary_to_term()
      Storehouse.analyze_now(file, steps, opts)
    end
  end
end
