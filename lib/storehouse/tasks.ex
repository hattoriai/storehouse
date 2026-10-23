defmodule Storehouse.Tasks do
  @moduledoc """
  The processes Storehouse's work out of a request runs in
  (`Storehouse.analyze_later/3`): a `Task.Supervisor` of the app's, with
  at most `:max_children` at once.

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {Storehouse.Tasks, max_children: 8},
        MyAppWeb.Endpoint
      ]

  Without it, the work runs at once, in the caller's process. Work not
  done when the app stops is not done: use Oban (`runner: :oban`) for work
  that must outlive a deploy.
  """

  @doc false
  def child_spec(opts) do
    opts = Keyword.validate!(opts, max_children: 4)

    %{
      id: __MODULE__,
      start:
        {Task.Supervisor, :start_link, [[name: __MODULE__, max_children: opts[:max_children]]]},
      type: :supervisor
    }
  end

  @doc false
  # Runs `fun` in a task of the supervisor, or at once without it (or when
  # it has as many as it takes).
  def run(fun) do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, _task} <- Task.Supervisor.start_child(__MODULE__, fun) do
      :ok
    else
      _none_or_full ->
        _result = fun.()
        :ok
    end
  end
end
