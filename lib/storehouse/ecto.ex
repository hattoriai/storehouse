if Code.ensure_loaded?(Ecto.Changeset) do
  defmodule Storehouse.Ecto do
    @moduledoc """
    Files in records, with Ecto: a column of type `Storehouse.Ecto.File`
    (or a list of them), files put in a changeset with `put_file/4`, made
    permanent when the record is saved, and deleted once nothing has them.

        schema "users" do
          field :name, :string
          field :avatar, Storehouse.Ecto.File
        end

        def changeset(user, attrs, avatar) do
          user
          |> cast(attrs, [:name])
          |> Storehouse.Ecto.put_file(:avatar, avatar, accept: Storehouse.Check.images(), max_bytes: 5_000_000)
        end

    ## Temporary, then permanent

    A file a person uploads for a form is temporary until the form is
    saved: store it with `cache: true` (`Storehouse.Live.allow/3` and
    `consume/3`, `Storehouse.store/2`), and its key is under the temporary
    prefix (`Storehouse.cache_prefix/0`). When the record is saved,
    `put_file/4` makes it permanent (`Storehouse.promote/2`): a copy in the
    store (on S3, in the bucket), in the save's transaction. A form never
    saved leaves its files under the prefix, where a lifecycle rule of the
    bucket deletes them:

        {"Rules": [{"ID": "storehouse-cache", "Status": "Enabled",
                    "Filter": {"Prefix": "cache/"},
                    "Expiration": {"Days": 1}}]}

    ## Replaced and deleted files

    A file the record no longer has (replaced, removed, or the record
    deleted) is deleted from the store once the database has the change:
    `insert/3`, `update/3` and `delete/3` save and then delete them.
    Inside a transaction of yours, use `Repo` as usual, and delete
    `replaced/2`'s files after your transaction commits: a rollback would
    otherwise leave a record whose file is gone.
    """

    import Ecto.Changeset

    require Ecto.Query

    @messages %{
      not_accepted: "is not a type that is accepted",
      too_large: "is too large",
      not_stored: "could not be stored"
    }

    @doc """
    Puts a file (a `Storehouse.File`, a list of them for a list field, or
    `nil` to remove it) in the changeset, checked, and made permanent when
    the record is saved.

    ## Options

      * `:accept` - the types the field takes (`Storehouse.Check.images()`).
      * `:max_bytes`, `:max_pixels` - the limits.
      * `:adapter` - the store, to make it permanent. The default is
        `Storehouse.adapter/0`.

    A file over a limit, or of a type not taken, is an error of the field
    (`validation: :storehouse`, with the `:reason`).
    """
    @spec put_file(
            Ecto.Changeset.t(),
            atom(),
            Storehouse.File.t() | [Storehouse.File.t()] | nil,
            keyword()
          ) ::
            Ecto.Changeset.t()
    def put_file(changeset, field, file_or_files, opts \\ []) do
      changeset = put_change(changeset, field, file_or_files)

      case Enum.find_value(List.wrap(file_or_files), &refusal(&1, opts)) do
        nil ->
          prepare_changes(changeset, &promote_field(&1, field, opts))

        reason ->
          add_error(changeset, field, @messages[reason], validation: :storehouse, reason: reason)
      end
    end

    @doc """
    Merges `metadata` into the metadata of the file in `field`
    (`Storehouse.File.put_metadata/2`): a caption, a credit, what a person
    entered. For a list field, give the `key` of the file. Metadata that
    JSON cannot hold is an error of the field (`validation: :storehouse`,
    `reason: {:invalid_metadata, path}`); a field with no such file is left
    as it is.

        photo
        |> Storehouse.Ecto.put_metadata(:image, %{"caption" => params["caption"]})
        |> Repo.update()
    """
    @spec put_metadata(Ecto.Changeset.t(), atom(), map()) :: Ecto.Changeset.t()
    def put_metadata(changeset, field, metadata) do
      case get_field(changeset, field) do
        %Storehouse.File{} = file -> put_metadata_of(changeset, field, file, metadata, & &1)
        _none -> changeset
      end
    end

    @spec put_metadata(Ecto.Changeset.t(), atom(), Storehouse.Adapter.key(), map()) ::
            Ecto.Changeset.t()
    def put_metadata(changeset, field, key, metadata) when is_binary(key) do
      files = get_field(changeset, field) || []

      case Enum.find(files, &(&1.key == key)) do
        nil ->
          changeset

        file ->
          put_metadata_of(changeset, field, file, metadata, &replace_file(files, key, &1))
      end
    end

    defp replace_file(files, key, updated),
      do: Enum.map(files, fn file -> if file.key == key, do: updated, else: file end)

    defp put_metadata_of(changeset, field, file, metadata, value) do
      case Storehouse.File.put_metadata(file, metadata) do
        {:ok, updated} ->
          put_change(changeset, field, value.(updated))

        {:error, reason} ->
          add_error(changeset, field, "has metadata that cannot be kept",
            validation: :storehouse,
            reason: reason
          )
      end
    end

    defp refusal(%Storehouse.File{} = file, opts) do
      pixels = if is_integer(file.width), do: file.width * (file.height || 0)

      cond do
        is_list(opts[:accept]) and file.content_type not in opts[:accept] -> :not_accepted
        over?(file.bytes, opts[:max_bytes]) or over?(pixels, opts[:max_pixels]) -> :too_large
        true -> nil
      end
    end

    defp over?(value, max), do: is_integer(value) and is_integer(max) and value > max

    # In the save's transaction: the temporary files of the field, made
    # permanent; a file that cannot be makes the save an error, and rolls it
    # back.
    defp promote_field(changeset, field, opts) do
      case fetch_change(changeset, field) do
        {:ok, value} -> promote_value(changeset, field, value, Keyword.take(opts, [:adapter]))
        # The record has the file already: nothing to make permanent.
        :error -> changeset
      end
    end

    defp promote_value(changeset, field, value, promote) do
      results = for file <- List.wrap(value), do: Storehouse.promote(file, promote)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil ->
          files = Enum.map(results, fn {:ok, file} -> file end)
          put_change(changeset, field, if(is_list(value), do: files, else: List.first(files)))

        {:error, reason} ->
          add_error(changeset, field, @messages.not_stored,
            validation: :storehouse,
            reason: reason
          )
      end
    end

    @doc """
    The files a saved changeset leaves behind: those its record had in a
    field of files, and does not have after it. Delete them once the
    transaction has committed (`delete_files/2`).
    """
    @spec replaced(Ecto.Changeset.t(), struct()) :: [Storehouse.File.t()]
    def replaced(%Ecto.Changeset{data: before}, %_{} = saved) do
      for field <- file_fields(saved),
          old = List.wrap(Map.get(before, field)),
          kept = MapSet.new(List.wrap(Map.get(saved, field)), & &1.key),
          file <- old,
          not MapSet.member?(kept, file.key),
          do: file
    end

    @doc "Every file of a record, in its fields of files."
    @spec files(struct()) :: [Storehouse.File.t()]
    def files(%_{} = record),
      do: Enum.flat_map(file_fields(record), &List.wrap(Map.get(record, &1)))

    @doc """
    Deletes files from the store (`Storehouse.delete_later/2`): queued in
    `Storehouse.Cleaner`, and tried again when the store fails, when the app
    runs it; at once otherwise.
    """
    @spec delete_files([Storehouse.File.t()], keyword()) :: :ok
    def delete_files(files, opts \\ []) do
      Enum.each(files, &Storehouse.delete_later(&1.key, Keyword.take(opts, [:adapter])))
    end

    @doc """
    `repo.insert/2`, as it is: the files are made permanent in its
    transaction (`put_file/4`).
    """
    @spec insert(module(), Ecto.Changeset.t(), keyword()) ::
            {:ok, struct()} | {:error, Ecto.Changeset.t()}
    def insert(repo, changeset, opts \\ []) do
      {analyze, opts} = Keyword.pop(opts, :analyze, [])

      with {:ok, saved} <- repo.insert(changeset, opts) do
        unless repo.in_transaction?(), do: analyze_new(repo, changeset.data, saved, analyze, opts)
        {:ok, saved}
      end
    end

    @doc """
    `repo.update/2`, then the files it replaced or removed are deleted from
    the store. Inside a transaction, they are not: delete `replaced/2`'s
    after it commits.
    """
    @spec update(module(), Ecto.Changeset.t(), keyword()) ::
            {:ok, struct()} | {:error, Ecto.Changeset.t()}
    def update(repo, changeset, opts \\ []) do
      {analyze, opts} = Keyword.pop(opts, :analyze, [])

      with {:ok, saved} <- repo.update(changeset, opts) do
        unless repo.in_transaction?() do
          delete_files(replaced(changeset, saved), opts)
          analyze_new(repo, changeset.data, saved, analyze, opts)
        end

        {:ok, saved}
      end
    end

    # The files of each field to analyze that the save put there.
    defp analyze_new(repo, before, saved, analyze, opts) do
      for {field, steps} <- analyze do
        known = MapSet.new(List.wrap(Map.get(before, field)), & &1.key)
        new = Enum.reject(List.wrap(Map.get(saved, field)), &MapSet.member?(known, &1.key))
        analyze_files(repo, saved, field, new, steps, opts)
      end

      :ok
    end

    @doc """
    Runs the analysis steps of the files in `field` out of the request
    (`Storehouse.analyze_later/3`), then saves their results in the
    record's column: only each file's analysis, the steps that ran
    merged into what it had, in a transaction that locks the row, so that what the app changed in
    the meantime stays. A file no longer in the record, or a record
    deleted, is left as it is.

        Storehouse.Ecto.analyze_later(Repo, user, :avatar, [MyApp.Analyzers.Colors])

    `insert/3` and `update/3` do it for the files a save puts in a field,
    with `analyze: [avatar: steps]`.

    Takes the options of `Storehouse.analyze_later/3` but `:then`
    (`:runner`, `:oban`, `:force`, `:max_bytes`, `:adapter`).
    """
    @spec analyze_later(module(), struct(), atom(), [Storehouse.Analyzer.step()], keyword()) ::
            :ok
    def analyze_later(repo, %_{} = record, field, steps, opts \\ []) do
      analyze_files(repo, record, field, List.wrap(Map.get(record, field)), steps, opts)
      :ok
    end

    defp analyze_files(repo, %schema{} = record, field, files, steps, opts) do
      [primary] = schema.__schema__(:primary_key)
      id = Map.fetch!(record, primary)
      later = Keyword.take(opts, [:runner, :oban, :force, :max_bytes, :adapter])

      for file <- files,
          do:
            Storehouse.analyze_later(
              file,
              steps,
              Keyword.put(later, :then, {__MODULE__, :save_analyzed, [repo, schema, id, field]})
            )
    end

    @doc false
    # The analysis of a file, saved in its record's column: only the file's
    # analysis, on the row as it is now.
    def save_analyzed(%Storehouse.File{} = analyzed, repo, schema, id, field) do
      [primary] = schema.__schema__(:primary_key)
      query = Ecto.Query.from(r in schema, where: field(r, ^primary) == ^id, lock: "FOR UPDATE")

      repo.transaction(fn ->
        with %_{} = record <- repo.one(query),
             value = Map.get(record, field),
             {:ok, updated} <- with_analysis(value, analyzed) do
          record |> change(%{field => updated}) |> repo.update!()
        end
      end)

      :ok
    end

    defp with_analysis(%Storehouse.File{key: key} = file, %Storehouse.File{key: key} = analyzed),
      do: {:ok, keep_analysis(file, analyzed)}

    defp with_analysis(files, %Storehouse.File{key: key} = analyzed) when is_list(files) do
      if Enum.any?(files, &(&1.key == key)),
        do: {:ok, Enum.map(files, &if(&1.key == key, do: keep_analysis(&1, analyzed), else: &1))},
        else: :gone
    end

    defp with_analysis(_value, _analyzed), do: :gone

    defp keep_analysis(file, analyzed),
      do: %{file | analysis: Map.merge(file.analysis || %{}, analyzed.analysis || %{})}

    @doc """
    `repo.delete/2`, then the record's files are deleted from the store.
    Inside a transaction, they are not: delete `files/1`'s after it
    commits.
    """
    @spec delete(module(), struct() | Ecto.Changeset.t(), keyword()) ::
            {:ok, struct()} | {:error, Ecto.Changeset.t()}
    def delete(repo, record_or_changeset, opts \\ []) do
      record = with %Ecto.Changeset{data: data} <- record_or_changeset, do: data

      with {:ok, deleted} <- repo.delete(record_or_changeset, opts) do
        unless repo.in_transaction?(), do: delete_files(files(record), opts)
        {:ok, deleted}
      end
    end

    # The fields of a schema whose type is Storehouse.Ecto.File, or a list of them.
    defp file_fields(%schema{}) do
      for field <- schema.__schema__(:fields),
          schema.__schema__(:type, field) in [
            Storehouse.Ecto.File,
            {:array, Storehouse.Ecto.File}
          ],
          do: field
    end
  end
end
