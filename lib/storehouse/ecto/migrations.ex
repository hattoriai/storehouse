if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Storehouse.Ecto.Migrations do
    @moduledoc """
    The tables of a library of files (`Storehouse.Ecto.Blob`,
    `Storehouse.Ecto.Usage`), for a migration of the app's:

        defmodule MyApp.Repo.Migrations.AddStorehouseBlobs do
          use Ecto.Migration

          def up, do: Storehouse.Ecto.Migrations.up()
          def down, do: Storehouse.Ecto.Migrations.down()
        end

    It makes two tables:

      * `storehouse_blobs` - a file a row: its key (unique), store, owner,
        name, type, size, checksum, width, height, metadata, analysis,
        `processing_error` and timestamps, with a UUID for its id. The same
        file of the same owner is one row (a unique index of the owner and
        the checksum).
      * `storehouse_usages` - which records use each file: the blob, the
        record's table and id. A blob a record uses cannot be deleted, by
        the database's own foreign key.

    Apps that keep their files in records' columns (`Storehouse.Ecto.File`)
    need neither.

    ## Options

      * `:blobs` and `:usages` - the tables' names. The defaults are
        `"storehouse_blobs"` and `"storehouse_usages"`.
      * `:unique_checksum` - `false` lets an owner keep the same file twice.
        The default is `true`.
      * `:prefix` - the database schema (PostgreSQL's) of the tables.
    """

    use Ecto.Migration

    @doc "Makes the tables."
    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      blobs = Keyword.get(opts, :blobs, "storehouse_blobs")
      usages = Keyword.get(opts, :usages, "storehouse_usages")
      prefix = opts[:prefix]

      create table(blobs, primary_key: false, prefix: prefix) do
        add(:id, :binary_id, primary_key: true)
        add(:key, :text, null: false)
        add(:store, :text)
        add(:owner, :text)
        add(:name, :text, null: false)
        add(:content_type, :text, null: false)
        add(:bytes, :bigint, null: false)
        add(:checksum, :text)
        add(:width, :integer)
        add(:height, :integer)
        add(:metadata, :map, null: false, default: %{})
        add(:analysis, :map, null: false, default: %{})
        add(:processing_error, :text)
        timestamps(type: :utc_datetime_usec)
      end

      create(unique_index(blobs, [:key], prefix: prefix))
      create(index(blobs, [:owner], prefix: prefix))

      if Keyword.get(opts, :unique_checksum, true) do
        create(
          unique_index(blobs, [:owner, :checksum],
            where: "checksum IS NOT NULL",
            name: "#{blobs}_owner_checksum_index",
            prefix: prefix
          )
        )
      end

      create table(usages, primary_key: false, prefix: prefix) do
        add(
          :blob_id,
          references(blobs, type: :binary_id, on_delete: :restrict, prefix: prefix),
          primary_key: true
        )

        add(:record_type, :text, primary_key: true)
        add(:record_id, :text, primary_key: true)
        add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      end

      create(index(usages, [:record_type, :record_id], prefix: prefix))
      :ok
    end

    @doc "Drops the tables."
    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      prefix = opts[:prefix]
      drop(table(Keyword.get(opts, :usages, "storehouse_usages"), prefix: prefix))
      drop(table(Keyword.get(opts, :blobs, "storehouse_blobs"), prefix: prefix))
      :ok
    end
  end
end
