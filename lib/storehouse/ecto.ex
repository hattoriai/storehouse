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
      not_stored: "could not be stored",
      not_owner: "is not a file of this owner",
      too_many: "has too many files"
    }

    @doc """
    Puts a file (a `Storehouse.File`, a list of them for a list field, or
    `nil` to remove it) in the changeset, checked, and made permanent when
    the record is saved.

    ## Options

      * `:accept` - the types the field takes (`Storehouse.Check.images()`).
      * `:max_bytes`, `:max_pixels` - the limits.
      * `:owner` - the owner the files must belong to
        (`Storehouse.owns?/2`): a file under another's prefix is an error
        of the field, so that a record never takes another's file.
      * `:max_files` - for a list field, the most files it holds.
      * `:adapter` - the store, to make it permanent. The default is
        `Storehouse.adapter/0`.

    A file over a limit, or of a type not taken, is an error of the field
    (`validation: :storehouse`, with the `:reason`). For a list field,
    `add_files/4` adds to the files the record has, and `remove_file/3`
    takes one away.
    """
    @spec put_file(
            Ecto.Changeset.t(),
            atom(),
            Storehouse.File.t() | [Storehouse.File.t()] | nil,
            keyword()
          ) ::
            Ecto.Changeset.t()
    def put_file(changeset, field, file_or_files, opts \\ []),
      do: put_checked(changeset, field, file_or_files, List.wrap(file_or_files), opts)

    @doc """
    Adds files to those of a list field, after the files the record has:
    each checked as `put_file/4` checks it, with the same options, and made
    permanent when the record is saved. `:max_files` counts them all.

        user
        |> change()
        |> Storehouse.Ecto.add_files(:photos, uploaded, accept: Storehouse.Check.images(), max_files: 20)
        |> then(&Storehouse.Ecto.update(Repo, &1))
    """
    @spec add_files(
            Ecto.Changeset.t(),
            atom(),
            Storehouse.File.t() | [Storehouse.File.t()],
            keyword()
          ) :: Ecto.Changeset.t()
    def add_files(changeset, field, file_or_files, opts \\ []) do
      added = List.wrap(file_or_files)
      put_checked(changeset, field, (get_field(changeset, field) || []) ++ added, added, opts)
    end

    @doc """
    Takes the file with `key` (or the file given) out of `field`: from a
    list field, or a single one, which is then `nil`. `update/3` deletes it
    from the store once the record is saved. A field without it is left as
    it is.

        user
        |> change()
        |> Storehouse.Ecto.remove_file(:photos, key)
        |> then(&Storehouse.Ecto.update(Repo, &1))
    """
    @spec remove_file(Ecto.Changeset.t(), atom(), Storehouse.File.t() | Storehouse.Adapter.key()) ::
            Ecto.Changeset.t()
    def remove_file(changeset, field, %Storehouse.File{key: key}),
      do: remove_file(changeset, field, key)

    def remove_file(changeset, field, key) when is_binary(key) do
      case get_field(changeset, field) do
        files when is_list(files) ->
          if Enum.any?(files, &(&1.key == key)),
            do: put_change(changeset, field, Enum.reject(files, &(&1.key == key))),
            else: changeset

        %Storehouse.File{key: ^key} ->
          put_change(changeset, field, nil)

        _other ->
          changeset
      end
    end

    # The value put in the field; the files of it checked, those that are new.
    defp put_checked(changeset, field, value, checked, opts) do
      changeset = put_change(changeset, field, value)

      case too_many(value, opts[:max_files]) || Enum.find_value(checked, &refusal(&1, opts)) do
        nil ->
          prepare_changes(changeset, &promote_field(&1, field, opts))

        reason ->
          add_error(changeset, field, @messages[reason], validation: :storehouse, reason: reason)
      end
    end

    defp too_many(files, max) when is_list(files) and is_integer(max) and length(files) > max,
      do: :too_many

    defp too_many(_value, _max), do: nil

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
        not owned?(file, opts[:owner]) -> :not_owner
        is_list(opts[:accept]) and file.content_type not in opts[:accept] -> :not_accepted
        over?(file.bytes, opts[:max_bytes]) or over?(pixels, opts[:max_pixels]) -> :too_large
        true -> nil
      end
    end

    defp owned?(_file, nil), do: true
    defp owned?(file, owner), do: Storehouse.owns?(owner, file.key)

    defp over?(value, max), do: is_integer(value) and is_integer(max) and value > max

    # In the save's transaction: the temporary files of the field, made
    # permanent; a file that cannot be makes the save an error, and rolls it
    # back.
    defp promote_field(changeset, field, opts) do
      case fetch_change(changeset, field) do
        {:ok, value} ->
          promote_value(changeset, field, value, store_opts(changeset.data, field, opts))

        # The record has the file already: nothing to make permanent.
        :error ->
          changeset
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
    transaction has committed (`delete_files/2`, with the field's store as
    `:adapter` when it has one, `store/2`).
    """
    @spec replaced(Ecto.Changeset.t(), struct()) :: [Storehouse.File.t()]
    def replaced(%Ecto.Changeset{} = changeset, %_{} = saved),
      do: Enum.flat_map(file_fields(saved), &replaced_in(changeset, saved, &1))

    defp replaced_in(%Ecto.Changeset{data: before}, saved, field) do
      kept = MapSet.new(List.wrap(Map.get(saved, field)), & &1.key)
      for file <- List.wrap(Map.get(before, field)), not MapSet.member?(kept, file.key), do: file
    end

    @doc "Every file of a record, in its fields of files."
    @spec files(struct()) :: [Storehouse.File.t()]
    def files(%_{} = record),
      do: Enum.flat_map(file_fields(record), &List.wrap(Map.get(record, &1)))

    @doc """
    Deletes files from the store (`Storehouse.delete_later/2`): jobs of the
    app's runner (`Storehouse.Runner`), tried again when the store fails.
    """
    @spec delete_files([Storehouse.File.t()], keyword()) :: :ok
    def delete_files(files, opts \\ []) do
      Enum.each(files, &Storehouse.delete_later(&1.key, Keyword.take(opts, [:adapter])))
    end

    # The files of each field deleted from the field's store.
    defp delete_by_field(record, files_of, opts) do
      for field <- file_fields(record),
          do: delete_files(files_of.(field), store_opts(record, field, opts))

      :ok
    end

    @doc """
    The store of a schema's field of files (its `store:`,
    `Storehouse.Ecto.File`), or `nil` for the default store.

        Storehouse.Ecto.store(Invoice, :pdf)
        #=> MyApp.PrivateFiles
    """
    @spec store(module(), atom()) :: module() | nil
    def store(schema, field) do
      case schema.__schema__(:type, field) do
        {:parameterized, {Storehouse.Ecto.File, params}} ->
          Storehouse.Ecto.File.store(params)

        {:array, {:parameterized, {Storehouse.Ecto.File, params}}} ->
          Storehouse.Ecto.File.store(params)

        _other ->
          nil
      end
    end

    # The store a field's files go to: the call's `:adapter`, the field's
    # `store:`, or the default.
    defp store_opts(%schema{}, field, opts) do
      case Keyword.get_lazy(opts, :adapter, fn -> store(schema, field) end) do
        nil -> []
        adapter -> [adapter: adapter]
      end
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
          delete_by_field(saved, &replaced_in(changeset, saved, &1), opts)
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
    (`:runner`, `:force`, `:max_bytes`, `:adapter`).
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

      later =
        opts
        |> Keyword.take([:runner, :force, :max_bytes])
        |> Keyword.merge(store_opts(record, field, opts))

      for file <- files,
          do:
            Storehouse.analyze_later(
              file,
              steps,
              Keyword.put(later, :then, {__MODULE__, :save_analyzed, [repo, schema, id, field]})
            )
    end

    @doc """
    Runs analysis steps over the files of `field` in every record
    `queryable` gives: a step added after files were stored (placeholders
    a year in), a step that failed, files from before analysis existed.

        Storehouse.Ecto.reprocess(Repo, MyApp.Photo, :image, [MyApp.Analyzers.Placeholder])
        #=> {:ok, %{records: 10_000, files: 9_412, skipped: 588, failed: []}}

    The records are read a batch at a time, in the order of their primary
    key, so a table of any size takes the memory of a batch. A file that
    has every step's result already is skipped, so it can be stopped and
    run again: it does only what is missing. `:after` starts after the
    primary key a run got to (`:on_progress` gives it).

    Each file is a job of the app's runner (`Storehouse.Runner`), which
    saves its results in the record's column as `analyze_later/5` does;
    with `now: true`, the steps run here instead, several files at once,
    and the results are saved before it returns. `mix storehouse.reprocess`
    runs it from the command line.

    ## Options

      * `:batch_size` - the records read at a time. The default is 500.
      * `:force` - every file, its steps run again. The default is
        `false`: only the files a step has yet to run on, or failed on.
      * `:now` - run the steps here, not as jobs. The default is `false`.
      * `:max_concurrency` - with `now: true`, how many files at once. The
        default is 4.
      * `:after` - the primary key to start after.
      * `:on_progress` - a function given, after each batch, the counts so
        far and `:last`, the batch's last primary key.
      * `:runner`, `:max_bytes` and `:adapter` - as for `analyze_later/5`.

    Gives the counts: the `:records` read, the `:files` analyzed (or given
    to the runner), those `:skipped`, done already, and those `:failed`,
    `{primary_key, file_key, reason}`. A span, `[:storehouse, :reprocess]`.
    """
    @spec reprocess(module(), Ecto.Queryable.t(), atom(), [Storehouse.Analyzer.step()], keyword()) ::
            {:ok, map()}
    def reprocess(repo, queryable, field, steps, opts \\ []) do
      query = Ecto.Queryable.to_query(queryable)
      {_source, schema} = query.from.source
      [primary] = schema.__schema__(:primary_key)
      batch = Keyword.get(opts, :batch_size, 500)
      meta = %{schema: schema, field: field}

      :telemetry.span([:storehouse, :reprocess], meta, fn ->
        summary =
          opts[:after]
          |> Stream.unfold(&page(repo, query, primary, field, &1, batch))
          |> Enum.reduce(%{records: 0, files: 0, skipped: 0, failed: []}, fn records, summary ->
            repo
            |> reprocessed(records, field, steps, opts, summary)
            |> progress(records, primary, opts)
          end)

        summary = %{summary | failed: Enum.reverse(summary.failed)}
        {{:ok, summary}, Map.put(meta, :summary, summary)}
      end)
    end

    # The counts so far, given to `:on_progress` with the batch's last key.
    defp progress(summary, records, primary, opts) do
      if fun = opts[:on_progress],
        do: fun.(Map.put(summary, :last, records |> List.last() |> Map.fetch!(primary)))

      summary
    end

    # A batch of records after `last`, in the order of their primary key.
    defp page(repo, query, primary, field, last, batch) do
      page =
        Ecto.Query.from(r in query,
          where: not is_nil(field(r, ^field)),
          order_by: [asc: field(r, ^primary)],
          limit: ^batch
        )

      page =
        if is_nil(last), do: page, else: Ecto.Query.where(page, [r], field(r, ^primary) > ^last)

      case repo.all(page) do
        [] -> nil
        records -> {records, Map.fetch!(List.last(records), primary)}
      end
    end

    defp reprocessed(repo, records, field, steps, opts, summary) do
      files = for record <- records, file <- List.wrap(Map.get(record, field)), do: {record, file}

      todo =
        Enum.filter(files, fn {_record, file} ->
          opts[:force] || Storehouse.Analyzer.pending?(file, steps)
        end)

      failed =
        for {{record, file}, {:error, reason}} <-
              Enum.zip(todo, analyzed(repo, todo, field, steps, opts)),
            do: {primary_key(record), file.key, reason}

      %{
        summary
        | records: summary.records + length(records),
          files: summary.files + length(todo),
          skipped: summary.skipped + length(files) - length(todo),
          failed: Enum.reverse(failed, summary.failed)
      }
    end

    defp primary_key(%schema{} = record) do
      [primary] = schema.__schema__(:primary_key)
      Map.fetch!(record, primary)
    end

    # Each file's result, in order: given to the runner, or, now, its
    # steps run and saved here.
    defp analyzed(repo, files, field, steps, opts) do
      if opts[:now] do
        files
        |> Task.async_stream(&analyze_now(repo, &1, field, steps, opts),
          max_concurrency: Keyword.get(opts, :max_concurrency, 4),
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)
      else
        for {record, file} <- files,
            do: hd(analyze_files(repo, record, field, [file], steps, opts))
      end
    end

    defp analyze_now(repo, {%schema{} = record, file}, field, steps, opts) do
      analyze_opts =
        opts
        |> Keyword.take([:force, :max_bytes])
        |> Keyword.merge(store_opts(record, field, opts))

      with {:ok, analyzed} <- Storehouse.analyze(file, steps, analyze_opts),
           do: save_analyzed(analyzed, repo, schema, primary_key(record), field)
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
        unless repo.in_transaction?(),
          do: delete_by_field(record, &List.wrap(Map.get(record, &1)), opts)

        {:ok, deleted}
      end
    end

    # The fields of a schema whose type is Storehouse.Ecto.File, or a list of them.
    defp file_fields(%schema{}) do
      for field <- schema.__schema__(:fields),
          file_type?(schema.__schema__(:type, field)),
          do: field
    end

    defp file_type?({:array, type}), do: file_type?(type)
    defp file_type?({:parameterized, {Storehouse.Ecto.File, _params}}), do: true
    defp file_type?(Storehouse.Ecto.File), do: true
    defp file_type?(_type), do: false
  end
end
