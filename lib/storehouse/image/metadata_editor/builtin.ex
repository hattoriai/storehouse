defmodule Storehouse.Image.MetadataEditor.Builtin do
  @moduledoc """
  Storehouse's own metadata editor (`Storehouse.Image.MetadataEditor`), in
  Elixir, with no dependency: JPEG (`Storehouse.Image.JPEG`), PNG
  (`Storehouse.Image.PNG`) and WebP (`Storehouse.Image.WebP`), each reading only a
  file's metadata into memory and copying its image data from file to
  file. Other types (HEIC, AVIF, TIFF, a camera's raw files) are
  `:unsupported`: an editor around ExifTool edits those.
  """

  @behaviour Storehouse.Image.MetadataEditor

  alias Storehouse.Image.{JPEG, PNG, WebP}

  @impl true
  def edit(from, to, "image/jpeg", changes),
    do: JPEG.edit_file(from, to, changes)

  def edit(from, to, "image/png", changes), do: PNG.edit_file(from, to, changes)

  def edit(from, to, "image/webp", changes),
    do: WebP.edit_file(from, to, changes)

  def edit(_from, _to, _content_type, _changes), do: :unsupported
end
