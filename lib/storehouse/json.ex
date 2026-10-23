defmodule Storehouse.JSON do
  @moduledoc false

  # Storehouse's JSON, in one place: every part of it that encodes or
  # decodes JSON calls this module, never a library. Elixir's own JSON
  # (1.18 and later) when it is there, else Jason.

  cond do
    Code.ensure_loaded?(JSON) ->
      defdelegate encode!(data), to: JSON
      defdelegate encode_to_iodata!(data), to: JSON
      defdelegate decode(data), to: JSON
      defdelegate decode!(data), to: JSON

    Code.ensure_loaded?(Jason) ->
      defdelegate encode!(data), to: Jason
      defdelegate encode_to_iodata!(data), to: Jason
      defdelegate decode(data), to: Jason
      defdelegate decode!(data), to: Jason

    true ->
      message = "Storehouse needs a JSON library: Elixir 1.18 or later, or `:jason` in your deps."

      IO.warn(message, Macro.Env.stacktrace(__ENV__))
  end
end
