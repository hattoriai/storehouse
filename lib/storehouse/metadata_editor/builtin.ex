defmodule Storehouse.MetadataEditor.Builtin do
  @moduledoc """
  Storehouse's own metadata editor (`Storehouse.MetadataEditor`), in
  Elixir, with no dependency: JPEG (`Storehouse.JPEG`), PNG
  (`Storehouse.PNG`) and WebP (`Storehouse.WebP`), each reading only a
  file's metadata into memory and copying its image data from file to
  file. Other types (HEIC, AVIF, TIFF, a camera's raw files) are
  `:unsupported`: an editor around ExifTool edits those.
  """

  @behaviour Storehouse.MetadataEditor

  @impl true
  def edit(from, to, "image/jpeg", changes), do: Storehouse.JPEG.edit_file(from, to, changes)
  def edit(from, to, "image/png", changes), do: Storehouse.PNG.edit_file(from, to, changes)
  def edit(from, to, "image/webp", changes), do: Storehouse.WebP.edit_file(from, to, changes)
  def edit(_from, _to, _content_type, _changes), do: :unsupported
end
