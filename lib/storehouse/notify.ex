defmodule Storehouse.Notify do
  @moduledoc """
  What happens to files, told to the app as it happens: a file stored, its
  analysis done or a step of it failed, a file deleted. For a page that
  shows the files to everyone who has it open, as their analysis comes
  in.

      # config/config.exs
      config :storehouse, notify: {MyApp.Files, :changed, []}

      defmodule MyApp.Files do
        def changed(event, info), do: ...
      end

  The function is called with the event and a map, then its own
  arguments, in the process that did the work:

    * `:stored` - `%{file: file}`, from `Storehouse.store/2` and
      `Storehouse.verify_upload/2`;
    * `:analyzed` - `%{file: file, steps: names}`, the file with the
      results of the steps that ran (`Storehouse.analyze/3`);
    * `:failed` - `%{file: file, step: name, reason: reason}`, a step that
      failed;
    * `:deleted` - `%{key: key}` (`Storehouse.delete/2`), or
      `%{prefix: prefix, count: count}` (`Storehouse.delete_prefix/2`).

  Each call that does the work takes `notify:` too, which is used in place
  of the config's (`notify: nil` tells nothing). A function that raises
  is logged, and the work is done all the same.

  `Storehouse.Notify.PubSub` broadcasts the events on a topic of the app's
  `Phoenix.PubSub`: a tenant's, so that one subscription follows all its
  files.
  """

  require Logger

  @typedoc "A function to tell: `{module, function, args}`, called with the event and its map first."
  @type notifier :: {module(), atom(), list()} | nil

  @doc false
  @spec notify(atom(), map(), keyword()) :: :ok
  def notify(event, info, opts) do
    case Keyword.get_lazy(opts, :notify, fn -> Application.get_env(:storehouse, :notify) end) do
      nil ->
        :ok

      {module, function, args} = notifier ->
        try do
          _result = apply(module, function, [event, info | args])
          :ok
        rescue
          exception ->
            Logger.warning(
              "Storehouse: #{inspect(notifier)} raised on #{inspect(event)}: " <>
                Exception.message(exception)
            )

            :ok
        end
    end
  end
end
