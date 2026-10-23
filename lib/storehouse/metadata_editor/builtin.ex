defmodule Storehouse.MetadataEditor.Builtin do
  @moduledoc """
  Storehouse's own metadata editor (`Storehouse.MetadataEditor`), in
  Elixir, with no dependency: JPEG, with `Storehouse.JPEG.edit_file/3`,
  which reads only a photo's metadata into memory and copies its image
  data from file to file. Other types are `:unsupported`.
  """

  @behaviour Storehouse.MetadataEditor

  @impl true
  def edit(from, to, "image/jpeg", changes), do: Storehouse.JPEG.edit_file(from, to, changes)
  def edit(_from, _to, _content_type, _changes), do: :unsupported
end
