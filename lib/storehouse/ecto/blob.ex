if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Storehouse.Ecto.Blob do
    @moduledoc """
    A library of files: a row a file, owned by someone (an account, a site),
    referenced from many records, kept when the record that first used it
    is deleted. Its tables are `Storehouse.Ecto.Migrations`'s; which records
    use each file is `Storehouse.Ecto.Usage`'s.

    For a file a record has alone (an avatar, an invoice), a column of the
    record is simpler: `Storehouse.Ecto.File`, with no table.

    This module is a schema of `storehouse_blobs`. An app with a table of its
    own, or fields of its own (a description, a credit), writes its schema
    with the same fields:

        defmodule MyApp.Photo do
          use Storehouse.Ecto.Blob.Schema, usages: "photo_usages"

          schema "photos" do
            Storehouse.Ecto.Blob.Schema.fields()
            field :alt_text, :string
          end
        end

    and gives it as `schema:` to this module's functions and
    `Storehouse.Ecto.Usage`'s. Its migration is
    `Storehouse.Ecto.Migrations.up(blobs: "photos", usages: "photo_usages")`,
    then its own columns.

    ## A file into the library

        {:ok, file} = Storehouse.store(upload.path, owner: "sites/7")
        {:ok, blob} = Storehouse.Ecto.Blob.insert(Repo, file, owner: "sites/7")

    The same file again, for the same owner, is the row the library has:
    `{:existing, blob}`, by the checksum.
    """

    use Storehouse.Ecto.Blob.Schema

    import Ecto.Query, only: [from: 2]

    alias Storehouse.Ecto.Blob.Schema, as: BlobSchema

    schema "storehouse_blobs" do
      BlobSchema.fields()
    end

    @type t :: struct()

    @doc """
    Puts a stored file in the library: `{:ok, blob}`, or `{:existing, blob}`
    when the owner has the same file already (by its checksum), or
    `{:error, changeset}`.

    ## Options

      * `:owner` - whose file it is: the same as `Storehouse.store/2`'s.
      * `:store` - the store it is kept in, a module. The default is
        `Storehouse.adapter/0`.
      * `:schema` - the blob schema. The default is this module.
      * `:attrs` - more fields of the app's schema: `%{alt_text: "…"}`.
    """
    @spec insert(module(), Storehouse.File.t(), keyword()) ::
            {:ok, t()} | {:existing, t()} | {:error, Ecto.Changeset.t()}
    def insert(repo, %Storehouse.File{} = file, opts \\ []) do
      schema = Keyword.get(opts, :schema, __MODULE__)
      owner = opts[:owner] && to_string(opts[:owner])
      store = Keyword.get_lazy(opts, :store, &Storehouse.adapter/0)
      source = schema.__schema__(:source)

      changeset =
        schema
        |> struct()
        |> Ecto.Changeset.change(
          Map.merge(
            %{
              key: file.key,
              store: inspect(store),
              owner: owner,
              name: file.name,
              content_type: file.content_type,
              bytes: file.bytes,
              checksum: file.checksum,
              width: file.width,
              height: file.height,
              metadata: file.metadata || %{},
              analysis: analysis(file)
            },
            Map.new(Keyword.get(opts, :attrs, %{}))
          )
        )
        |> Ecto.Changeset.unique_constraint(:key, name: "#{source}_key_index")
        |> Ecto.Changeset.unique_constraint([:owner, :checksum],
          name: "#{source}_owner_checksum_index"
        )

      case repo.insert(changeset) do
        {:ok, blob} ->
          {:ok, blob}

        {:error, %{errors: errors} = changeset} ->
          with true <- Keyword.has_key?(errors, :owner),
               %_{} = existing <- existing(repo, schema, owner, file.checksum) do
            {:existing, existing}
          else
            _other -> {:error, changeset}
          end
      end
    end

    defp existing(_repo, _schema, _owner, nil), do: nil

    defp existing(repo, schema, owner, checksum) do
      query =
        if owner,
          do: from(b in schema, where: b.owner == ^owner and b.checksum == ^checksum),
          else: from(b in schema, where: is_nil(b.owner) and b.checksum == ^checksum)

      repo.one(query)
    end

    defp analysis(%Storehouse.File{analysis: analysis}) when is_map(analysis),
      do: Map.new(analysis, fn {step, result} -> {step, Storehouse.Analysis.to_map(result)} end)

    defp analysis(_file), do: %{}

    @doc """
    The blob as a `Storehouse.File`, with its URL in its store: to show
    it, sign it, make its variants.
    """
    @spec to_file(struct()) :: Storehouse.File.t()
    def to_file(%{key: key} = blob) do
      adapter =
        case Storehouse.Job.module(blob.store || inspect(Storehouse.adapter())) do
          {:ok, module} -> module
          _unknown -> Storehouse.adapter()
        end

      %Storehouse.File{
        key: key,
        url: adapter.url(key),
        name: blob.name,
        content_type: blob.content_type,
        bytes: blob.bytes,
        checksum: blob.checksum,
        width: blob.width,
        height: blob.height,
        metadata: blob.metadata || %{},
        analysis:
          Map.new(blob.analysis || %{}, fn {step, map} ->
            {step, Storehouse.Analysis.from_map(map)}
          end)
      }
    end

    @doc """
    Checks that every id of `ids` is a blob of `owner`, before a record
    refers to them: `{:ok, ids}`, or `{:error, {:not_owned, ids}}` with those
    that are not (another's, or none at all). For ids a form or a document
    sends, which are never to be trusted.

    ## Options

      * `:schema` - the blob schema. The default is this module.
    """
    @spec owned(module(), [String.t()], String.t() | integer() | nil, keyword()) ::
            {:ok, [String.t()]} | {:error, {:not_owned, [String.t()]}}
    def owned(repo, ids, owner, opts \\ []) when is_list(ids) do
      schema = Keyword.get(opts, :schema, __MODULE__)
      ids = Enum.uniq(ids)
      uuids = Enum.flat_map(ids, &cast_id/1)
      owner = owner && to_string(owner)

      found =
        if uuids == [] do
          MapSet.new()
        else
          query =
            if owner,
              do: from(b in schema, where: b.id in ^uuids and b.owner == ^owner, select: b.id),
              else: from(b in schema, where: b.id in ^uuids and is_nil(b.owner), select: b.id)

          query |> repo.all() |> MapSet.new()
        end

      case Enum.reject(ids, &(cast_id(&1) |> List.first() |> then(fn id -> id in found end))) do
        [] -> {:ok, ids}
        missing -> {:error, {:not_owned, missing}}
      end
    end

    @doc """
    In a changeset, the error `"is not a file of yours"` on `field` (a list
    of blob ids) for any id that is not a blob of `owner` (`owned/4`).
    """
    @spec validate_owned(Ecto.Changeset.t(), atom(), module(), term(), keyword()) ::
            Ecto.Changeset.t()
    def validate_owned(changeset, field, repo, owner, opts \\ []) do
      Ecto.Changeset.validate_change(changeset, field, fn ^field, ids ->
        case owned(repo, List.wrap(ids), owner, opts) do
          {:ok, _ids} -> []
          {:error, {:not_owned, missing}} -> [{field, {"is not a file of yours", ids: missing}}]
        end
      end)
    end

    defp cast_id(id) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end
  end
end
