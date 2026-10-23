defmodule Storehouse.Analyzer.EditMetadata do
  @moduledoc """
  A step (`Storehouse.Analyzer`) that edits the metadata inside a stored
  JPEG without re-encoding it (`Storehouse.JPEG`), and writes the edited
  file back over the original, under `"edit_metadata"`.

  It does nothing unless asked: an app adds it to its steps, with what to
  change.

      # Where photos were taken, removed before they are shown.
      Storehouse.analyze(file, [{Storehouse.Analyzer.EditMetadata, strip: :gps}])

      # Only a few tags kept, and the author's name written in.
      Storehouse.analyze(file, [
        {Storehouse.Analyzer.EditMetadata,
         strip: {:keep, [:orientation, :copyright]},
         put: %{artist: "Ana Sousa", copyright: "© Ana Sousa"}}
      ])

  Options:

    * `:strip` - `:gps`, or `{:keep, tags}` (`Storehouse.JPEG.strip/2`).
    * `:put` - tags to write, or remove with `nil`
      (`Storehouse.JPEG.put_tags/2`), after `:strip`.

  With neither, or for a file that is not a JPEG (PNG, WebP, HEIC are
  left as they are), the step is `:skipped`. A JPEG it cannot read fails
  the step, with why, and the stored file is left as it was.

  Its result: `"changed"`, whether the file was rewritten; and when it
  was, its `"bytes"` and `"checksum"` now, and what was done
  (`"stripped"`, `"put"`). The steps after it read the edited file.

  ## Checksums

  The file's `:checksum` stays the one of the file as it was uploaded,
  which is what `:existing` compares to find the same upload again
  (`Storehouse.store/2`): an upload of the same photo still finds it. The
  checksum of what is stored now is the step's `"checksum"`, and
  `Storehouse.checksum/1` gives it of a copy.
  """

  @behaviour Storehouse.Analyzer

  @impl true
  def name, do: "edit_metadata"

  @impl true
  def analyze(%Storehouse.File{content_type: "image/jpeg"} = file, path, opts) do
    strip = opts[:strip]
    put = opts[:put] || %{}

    if strip == nil and put == %{},
      do: :skip,
      else: edit(file, path, strip, put, opts[:adapter])
  end

  def analyze(_file, _path, _opts), do: :skip

  defp edit(file, path, strip, put, adapter) do
    with {:ok, original} <- File.read(path),
         {:ok, edited} <- stripped(original, strip),
         {:ok, edited} <- Storehouse.JPEG.put_tags(edited, put) do
      if edited == original,
        do: {:ok, %{"changed" => false}},
        else: write(file, edited, adapter, done(strip, put))
    end
  end

  defp stripped(jpeg, nil), do: {:ok, jpeg}
  defp stripped(jpeg, strip), do: Storehouse.JPEG.strip(jpeg, strip)

  defp done(strip, put) do
    %{
      "stripped" =>
        case strip do
          nil -> nil
          :gps -> "gps"
          {:keep, tags} -> %{"kept" => Enum.map(tags, &Atom.to_string/1)}
        end,
      "put" => put |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end

  # The edited file over the original, from a temporary file the steps
  # after this one read.
  defp write(file, edited, adapter, done) do
    path =
      Path.join(System.tmp_dir!(), "storehouse-edited-#{System.unique_integer([:positive])}")

    checksum = Base.encode64(:crypto.hash(:sha256, edited))
    meta = %{content_type: file.content_type, bytes: byte_size(edited), checksum: checksum}
    File.write!(path, edited)

    case adapter.put(file.key, path, meta) do
      {:ok, _url} ->
        result =
          Map.merge(done, %{"changed" => true, "bytes" => meta.bytes, "checksum" => checksum})

        {:ok, result, path}

      {:error, reason} ->
        File.rm(path)
        {:error, reason}
    end
  end
end
