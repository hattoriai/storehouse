defmodule Storehouse.JSON do
  @moduledoc false

  # Storehouse's JSON, in one place: every part of it that encodes or
  # decodes JSON calls this module, never a library. The library is the
  # app's choice:
  #
  #     config :storehouse, :json_library, Jason
  #
  # and by default Elixir's own JSON (1.18 and later) when it is there,
  # else Jason.

  @default (cond do
              Code.ensure_loaded?(JSON) -> JSON
              Code.ensure_loaded?(Jason) -> Jason
              true -> nil
            end)

  if is_nil(@default) do
    IO.warn(
      "Storehouse needs a JSON library: Elixir 1.18 or later, or `:jason` in your deps.",
      Macro.Env.stacktrace(__ENV__)
    )
  end

  @doc false
  def library, do: Application.get_env(:storehouse, :json_library, @default)

  def encode!(data), do: library().encode!(data)
  def encode_to_iodata!(data), do: library().encode_to_iodata!(data)
  def decode(data), do: library().decode(data)
  def decode!(data), do: library().decode!(data)
end
