defmodule Storehouse.Analyzer.EditMetadata do
  @moduledoc """
  A step (`Storehouse.Analyzer`) that edits the metadata inside a stored
  file without re-encoding it, and writes the edited file back over the
  original, under `"edit_metadata"`.

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

    * `:strip` - `:gps`, or `{:keep, tags}` (`Storehouse.MetadataEditor`).
    * `:put` - tags to write, or remove with `nil`, after `:strip`.
    * `:editor` - what makes the changes (`Storehouse.MetadataEditor`).
      The default is `config :storehouse, :metadata_editor`, else
      Storehouse's own, `Storehouse.MetadataEditor.Builtin`, which edits
      JPEG, PNG and WebP.

  With neither change, or for a type the editor does not edit, the step
  is `:skipped` and the file left as it is. A file the editor cannot read
  fails the step, with why, and the stored file is left as it was.

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
  def analyze(%Storehouse.File{} = file, path, opts) do
    changes =
      Enum.reject([strip: opts[:strip], put: opts[:put]], fn {_change, value} ->
        value in [nil, %{}]
      end)

    if changes == [], do: :skip, else: edit(file, path, changes, opts)
  end

  defp edit(file, path, changes, opts) do
    to = Path.join(System.tmp_dir!(), "storehouse-edited-#{System.unique_integer([:positive])}")
    editor = Storehouse.MetadataEditor.editor(opts)

    case edited(editor, path, to, file.content_type, changes) do
      :ok ->
        written(file, path, to, changes, opts[:adapter])

      :unchanged ->
        {:ok, %{"changed" => false}}

      :unsupported ->
        :skip

      {:error, reason} ->
        File.rm(to)
        {:error, reason}
    end
  end

  # An editor that raises leaves no file behind.
  defp edited(editor, path, to, content_type, changes) do
    editor.edit(path, to, content_type, changes)
  rescue
    exception ->
      File.rm(to)
      reraise exception, __STACKTRACE__
  end

  # The edited file over the original, from the temporary file the steps
  # after this one read; unless the edit changed no byte.
  defp written(file, path, to, changes, adapter) do
    checksum = Storehouse.checksum(to)

    with false <- checksum == Storehouse.checksum(path),
         bytes = File.stat!(to).size,
         meta = %{content_type: file.content_type, bytes: bytes, checksum: checksum},
         {:ok, _url} <- adapter.put(file.key, to, meta) do
      done = %{"changed" => true, "bytes" => bytes, "checksum" => checksum}
      {:ok, Map.merge(done(changes), done), to}
    else
      true ->
        File.rm(to)
        {:ok, %{"changed" => false}}

      {:error, reason} ->
        File.rm(to)
        {:error, reason}
    end
  end

  defp done(changes) do
    %{
      "stripped" =>
        case changes[:strip] do
          nil -> nil
          :gps -> "gps"
          {:keep, tags} -> %{"kept" => Enum.map(tags, &Atom.to_string/1)}
        end,
      "put" => (changes[:put] || %{}) |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end
end
