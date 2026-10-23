defmodule Storehouse.Image.MetadataEditor do
  @moduledoc """
  What edits the metadata inside a stored file for the
  `Storehouse.Analyzer.EditMetadata` step: Storehouse's own
  (`Storehouse.Image.MetadataEditor.Builtin`, in Elixir, for JPEG, PNG and
  WebP), or one of
  the app's, around ExifTool, a NIF, a service.

  The changes are Storehouse's, whichever editor makes them:

    * `strip: :gps` - where the photo was taken.
    * `strip: {:keep, tags}` - all metadata but the tags named
      (`Storehouse.Image.JPEG` lists them by name), and what draws the image.
    * `put: %{artist: _, copyright: _, image_description: _}` - tags
      written, or removed with `nil`, after `:strip`.

  An editor reads the file at `from`, writes the edited file to `to`,
  and never changes `from`. It answers `:unsupported` for a type it does
  not edit, and the step is skipped; `:unchanged` when there is nothing to
  change (the step also sees an edit that changed no byte).

  ## Another editor

  For every step, in config:

      config :storehouse, :metadata_editor, MyApp.ExifTool

  or for one, as the step's `:editor`. One around ExifTool, which edits
  the formats Storehouse's does not:

      defmodule MyApp.ExifTool do
        @behaviour Storehouse.Image.MetadataEditor

        @tags %{artist: "Artist", copyright: "Copyright", image_description: "ImageDescription"}

        @impl true
        def edit(from, to, _content_type, changes) do
          args =
            Enum.flat_map(changes, fn
              {:strip, :gps} -> ["-gps:all=", "-xmp-exif:gps*="]
              {:put, tags} -> for {tag, value} <- tags, do: "-\#{@tags[tag]}=\#{value}"
            end)

          case System.cmd("exiftool", args ++ ["-o", to, from], stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {output, _status} -> {:error, output}
          end
        end
      end
  """

  @typedoc "A change, as above."
  @type change ::
          {:strip, :gps | {:keep, [atom()]}}
          | {:put, %{optional(atom()) => String.t() | nil}}

  @typedoc "The changes, made in this order: `:strip`, then `:put`."
  @type changes :: [change()]

  @doc "Writes the file at `from`, with `changes` made, to `to`."
  @callback edit(from :: Path.t(), to :: Path.t(), content_type :: String.t(), changes()) ::
              :ok | :unchanged | :unsupported | {:error, term()}

  @doc false
  # The editor of a step: its own, else the app's, else Storehouse's.
  @spec editor(keyword()) :: module()
  def editor(opts) do
    opts[:editor] ||
      Application.get_env(:storehouse, :metadata_editor, Storehouse.Image.MetadataEditor.Builtin)
  end
end
