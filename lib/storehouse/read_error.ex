defmodule Storehouse.ReadError do
  @moduledoc """
  Raised while a stream of `Storehouse.stream/2` is taken, when the store
  fails to give the next chunk: its `:key`, and the store's `:reason`.
  """

  defexception [:key, :reason]

  @impl true
  def message(%__MODULE__{key: key, reason: reason}),
    do: "could not read #{inspect(key)} from the store: #{inspect(reason)}"
end
