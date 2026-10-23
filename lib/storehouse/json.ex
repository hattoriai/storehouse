defmodule Storehouse.JSON do
  @moduledoc false

  # Storehouse's JSON, in one place: every part of it that encodes or
  # decodes JSON calls this module, never a library. It is Elixir's own
  # `JSON` (Elixir 1.18 and later, as Storehouse needs).

  defdelegate encode!(data), to: JSON
  defdelegate encode_to_iodata!(data), to: JSON
  defdelegate decode(data), to: JSON
  defdelegate decode!(data), to: JSON
end
