if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Storehouse.Ecto.Blob.Schema do
    @moduledoc """
    A blob schema of the app's own (`Storehouse.Ecto.Blob`): its primary
    key a UUID, its timestamps in microseconds, its usage table, and
    `fields/0` in its `schema` block.

        defmodule MyApp.Photo do
          use Storehouse.Ecto.Blob.Schema, usages: "photo_usages"

          schema "photos" do
            Storehouse.Ecto.Blob.Schema.fields()
            field :alt_text, :string
          end
        end

    ## Options

      * `:usages` - the usage table (`Storehouse.Ecto.Usage`). The default
        is `"storehouse_usages"`.
    """

    @doc false
    defmacro __using__(opts) do
      usages = Keyword.get(opts, :usages, "storehouse_usages")

      quote do
        use Ecto.Schema

        @primary_key {:id, :binary_id, autogenerate: true}
        @foreign_key_type :binary_id
        @timestamps_opts [type: :utc_datetime_usec]

        @doc false
        def __storehouse_usages__, do: unquote(usages)
      end
    end

    @doc "The fields of a blob: a migration's (`Storehouse.Ecto.Migrations`) columns."
    defmacro fields do
      quote do
        field(:key, :string)
        field(:store, :string)
        field(:owner, :string)
        field(:name, :string)
        field(:content_type, :string)
        field(:bytes, :integer)
        field(:checksum, :string)
        field(:width, :integer)
        field(:height, :integer)
        field(:metadata, :map, default: %{})
        field(:analysis, :map, default: %{})
        field(:processing_error, :string)
        timestamps()
      end
    end
  end
end
