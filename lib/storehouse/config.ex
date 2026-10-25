defmodule Storehouse.Config do
  @moduledoc false
  # A store's config (`Storehouse.S3`, `Storehouse.Local`, `Storehouse.Purge`):
  # the keyword list in the app's config, or `{module, function, args}` that
  # gives it each time it is needed, so that an app whose keys are kept
  # encrypted (in a vault, in its database) gives them only then, and never
  # leaves them in the application's environment.

  @doc false
  def get(app, key) do
    case Application.get_env(app, key, []) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        case apply(module, function, args) do
          config when is_list(config) ->
            config

          other ->
            raise ArgumentError,
                  "#{inspect(key)}'s config function #{inspect(module)}.#{function} gave " <>
                    "#{inspect(other, limit: 3)}, not a keyword list"
        end

      config ->
        config
    end
  end
end
