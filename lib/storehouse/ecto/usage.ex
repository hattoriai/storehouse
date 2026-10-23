if Code.ensure_loaded?(Ecto.Query) do
  defmodule Storehouse.Ecto.Usage do
    @moduledoc """
    Which records use each file of a library (`Storehouse.Ecto.Blob`): kept
    as the records change, so the library can say what each file is used
    by, and refuse to delete one that is used.

    A record says which files it uses now, each time it is saved, in the
    same transaction: a document whose blocks carry blob ids in JSON, a
    page with a cover and a gallery.

        Repo.transaction(fn ->
          story = Repo.update!(changeset)
          ids = for %{"image_id" => id} <- story.blocks, do: id
          {:ok, _} = Storehouse.Ecto.Usage.record(Repo, story, ids)
          story
        end)

    A record is named by its table and its primary key, so any schema's
    records use files, with no column for each. A record deleted uses none:
    `forget/3`.

        Storehouse.Ecto.Usage.used_by(Repo, blob)
        #=> [%{type: "stories", id: "42"}]

        Storehouse.Ecto.Usage.delete(Repo, blob)
        #=> {:error, {:in_use, [%{type: "stories", id: "42"}]}}

    The usage table's foreign key refuses the deletion of a blob that is
    used in the database itself, so two requests at once never delete a
    file a record has just started to use.

    Every function takes `:schema`, the blob schema (`Storehouse.Ecto.Blob`
    by default); the usage table is the schema's (`use Storehouse.Ecto.Blob.Schema,
    usages: …`).
    """

    import Ecto.Query, only: [from: 2]

    @typedoc "A record that uses a file: its table and its primary key."
    @type user :: %{type: String.t(), id: String.t()}

    @doc """
    Makes `blob_ids` the files `record` uses, all of them: those it used and
    no longer does are let go. Gives `{:ok, %{added: n, removed: n}}`, or
    `{:error, {:unknown, ids}}` for ids that are no blob, and nothing is
    changed.

    It does not check whose the files are: check ids from a form or a
    document with `Storehouse.Ecto.Blob.owned/4` first.
    """
    @spec record(module(), struct(), [String.t()], keyword()) ::
            {:ok, %{added: non_neg_integer(), removed: non_neg_integer()}}
            | {:error, {:unknown, [String.t()]}}
    def record(repo, record, blob_ids, opts \\ []) when is_list(blob_ids) do
      schema = Keyword.get(opts, :schema, Storehouse.Ecto.Blob)
      table = schema.__storehouse_usages__()
      %{type: type, id: id} = name(record)

      with {:ok, ids} <- cast(blob_ids),
           [] <- unknown(repo, schema, ids) do
        repo.transaction(fn -> replace(repo, table, type, id, ids) end)
      else
        {:error, _reason} = error -> error
        unknown when is_list(unknown) -> {:error, {:unknown, unknown}}
      end
    end

    # The record's usages: those of other blobs let go, the new ones added.
    defp replace(repo, table, type, id, ids) do
      {removed, _} =
        repo.delete_all(
          from(u in table,
            where: u.record_type == ^type and u.record_id == ^id and u.blob_id not in ^dump(ids)
          )
        )

      rows = for blob <- ids, do: %{blob_id: dump!(blob), record_type: type, record_id: id}
      {added, _} = repo.insert_all(table, rows, on_conflict: :nothing)
      %{added: added, removed: removed}
    end

    @doc "`record` uses no file any more: for a record deleted."
    @spec forget(module(), struct(), keyword()) :: {:ok, %{added: 0, removed: non_neg_integer()}}
    def forget(repo, record, opts \\ []), do: record(repo, record, [], opts)

    @doc "The records that use `blob` (a blob, or its id)."
    @spec used_by(module(), struct() | String.t(), keyword()) :: [user()]
    def used_by(repo, blob, opts \\ []) do
      schema = Keyword.get(opts, :schema, Storehouse.Ecto.Blob)

      repo.all(
        from(u in schema.__storehouse_usages__(),
          where: u.blob_id == ^dump!(id(blob)),
          order_by: [u.record_type, u.record_id],
          select: %{type: u.record_type, id: u.record_id}
        )
      )
    end

    @doc "The ids of the files `record` uses."
    @spec used(module(), struct(), keyword()) :: [String.t()]
    def used(repo, record, opts \\ []) do
      schema = Keyword.get(opts, :schema, Storehouse.Ecto.Blob)
      %{type: type, id: id} = name(record)

      from(u in schema.__storehouse_usages__(),
        where: u.record_type == ^type and u.record_id == ^id,
        select: u.blob_id
      )
      |> repo.all()
      |> Enum.map(&Ecto.UUID.load!/1)
      |> Enum.sort()
    end

    @doc """
    Deletes `blob` from the library, and then its file from the store
    (`Storehouse.delete_later/2`), unless a record uses it:
    `{:error, {:in_use, records}}`, and nothing is deleted.

    Inside a transaction of the app's, the file is not deleted: delete it
    after the transaction commits, as a rollback would bring the row back.
    """
    @spec delete(module(), struct(), keyword()) ::
            {:ok, struct()} | {:error, {:in_use, [user()]}} | {:error, Ecto.Changeset.t()}
    def delete(repo, blob, opts \\ []) do
      outer? = repo.in_transaction?()

      result =
        repo.transaction(fn ->
          # The row, held until the transaction ends: no record starts to
          # use it in between.
          locked =
            repo.one!(from(b in blob.__struct__, where: b.id == ^blob.id, lock: "FOR UPDATE"))

          case used_by(repo, locked, opts) do
            [] -> deleted(repo, locked)
            records -> repo.rollback({:in_use, records})
          end
        end)

      with {:ok, deleted} <- result do
        unless outer?, do: delete_file(deleted, opts)
        {:ok, deleted}
      end
    rescue
      # The foreign key: a record started to use it all the same.
      error in Ecto.ConstraintError ->
        if error.type == :foreign_key,
          do: {:error, {:in_use, used_by(repo, blob, opts)}},
          else: reraise(error, __STACKTRACE__)
    end

    defp deleted(repo, blob) do
      case repo.delete(blob) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> repo.rollback(changeset)
      end
    end

    defp delete_file(blob, opts) do
      adapter =
        case Storehouse.Job.module(blob.store || "") do
          {:ok, module} -> module
          _unknown -> Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
        end

      Storehouse.delete_later(blob.key, adapter: adapter)
    end

    # A record's table and its primary key, as text.
    defp name(%schema{} = record) do
      case schema.__schema__(:primary_key) do
        [key] ->
          %{type: schema.__schema__(:source), id: to_string(Map.fetch!(record, key))}

        _keys ->
          raise ArgumentError, "#{inspect(schema)}: a record that uses files has one primary key"
      end
    end

    defp id(%{id: id}), do: id
    defp id(id) when is_binary(id), do: id

    defp cast(ids) do
      Enum.reduce_while(Enum.uniq(ids), {:ok, []}, fn id, {:ok, acc} ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
          :error -> {:halt, {:error, {:unknown, [id]}}}
        end
      end)
      |> then(fn
        {:ok, ids} -> {:ok, Enum.uniq(ids)}
        error -> error
      end)
    end

    defp unknown(_repo, _schema, []), do: []

    defp unknown(repo, schema, ids) do
      found = repo.all(from(b in schema, where: b.id in ^ids, select: b.id)) |> MapSet.new()
      Enum.reject(ids, &(&1 in found))
    end

    defp dump(ids), do: Enum.map(ids, &dump!/1)
    defp dump!(id), do: Ecto.UUID.dump!(id)
  end
end
