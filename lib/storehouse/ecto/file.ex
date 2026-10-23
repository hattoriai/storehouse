if Code.ensure_loaded?(Ecto.Type) do
  defmodule Storehouse.Ecto.File do
    @moduledoc """
    An Ecto type for a stored file (`Storehouse.File`) in a record's column:
    a map (`jsonb` in PostgreSQL) of its key, URL, name, type, size,
    checksum, width, height, metadata (`Storehouse.Metadata`) and analysis
    (`Storehouse.Analysis`, each step's as `Storehouse.Analysis.to_map/1`). No table of files: the record has its file.

        schema "users" do
          field :avatar, Storehouse.Ecto.File
          field :photos, {:array, Storehouse.Ecto.File}, default: []
        end

        # The migration
        add :avatar, :map
        add :photos, {:array, :map}, default: []

    It casts a `Storehouse.File` only, never a map of a form's params: a
    file's key comes from Storehouse, never from a browser, so that no one
    puts another's file in their record. Put files with
    `Storehouse.Ecto.put_file/4`.

    ## A store of the field's own

    `store:` names the store the field's files are kept in (a module of
    `use Storehouse.S3` or `use Storehouse.Local`): `Storehouse.Ecto` makes
    them permanent there, deletes them from there, and analyzes them from
    there. The default is `Storehouse.adapter/0`.

        field :invoice, Storehouse.Ecto.File, store: MyApp.PrivateFiles
        field :scans, {:array, Storehouse.Ecto.File}, store: MyApp.PrivateFiles, default: []
    """

    use Ecto.ParameterizedType

    @fields ~w(key url name content_type bytes width height checksum preview metadata)a

    @impl true
    def init(opts), do: %{store: Keyword.get(opts, :store)}

    @doc "The store of a field's files, as `init/1` keeps it: a module, or `nil`."
    @spec store(map()) :: module() | nil
    def store(%{store: store}), do: store
    def store(_params), do: nil

    @impl true
    def type(_params), do: :map

    @impl true
    def cast(%Storehouse.File{} = file, _params), do: {:ok, file}
    def cast(nil, _params), do: {:ok, nil}
    def cast(_other, _params), do: :error

    @impl true
    def load(nil, _loader, _params), do: {:ok, nil}
    def load(%{} = map, _loader, _params), do: from_map(map)
    def load(_other, _loader, _params), do: :error

    @impl true
    def dump(nil, _dumper, _params), do: {:ok, nil}

    def dump(%Storehouse.File{} = file, _dumper, _params) do
      map = file |> Map.take(@fields) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      analysis =
        Map.new(file.analysis || %{}, fn {step, a} -> {step, Storehouse.Analysis.to_map(a)} end)

      {:ok, if(analysis == %{}, do: map, else: Map.put(map, "analysis", analysis))}
    end

    def dump(_other, _dumper, _params), do: :error

    @impl true
    def embed_as(_format, _params), do: :dump

    @impl true
    # The same file, with the same metadata and analysis: a caption changed,
    # or a step that ran, is a change.
    def equal?(
          %Storehouse.File{key: key, checksum: sum, metadata: metadata, analysis: analysis},
          %Storehouse.File{key: key, checksum: sum, metadata: metadata, analysis: analysis},
          _params
        ),
        do: true

    def equal?(a, b, _params), do: a == b

    # Each step's analysis; one the column cannot give back is left out.
    defp analysis(%{} = steps) do
      for {step, map} <- steps,
          analysis = Storehouse.Analysis.from_map(map),
          not is_nil(analysis),
          into: %{},
          do: {step, analysis}
    end

    defp analysis(_none), do: %{}

    defp from_map(map) do
      fields =
        Map.new(@fields, fn field ->
          {field, Map.get(map, Atom.to_string(field), Map.get(map, field))}
        end)

      if is_binary(fields.key) and is_binary(fields.url) and is_binary(fields.content_type) and
           is_integer(fields.bytes),
         do:
           {:ok,
            struct!(Storehouse.File, %{
              fields
              | name: fields.name || Path.basename(fields.key),
                metadata: if(is_map(fields.metadata), do: fields.metadata, else: %{})
            })
            |> Map.put(:analysis, analysis(Map.get(map, "analysis")))},
         else: :error
    end
  end
end
