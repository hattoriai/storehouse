if Code.ensure_loaded?(Ecto.Type) do
  defmodule Storehouse.Ecto.File do
    @moduledoc """
    An Ecto type for a stored file (`Storehouse.File`) in a record's column:
    a map (`jsonb` in PostgreSQL) of its key, URL, name, type, size,
    checksum, width and height. No table of files: the record has its file.

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
    """

    use Ecto.Type

    @fields ~w(key url name content_type bytes width height checksum preview)a

    @impl true
    def type, do: :map

    @impl true
    def cast(%Storehouse.File{} = file), do: {:ok, file}
    def cast(_other), do: :error

    @impl true
    def load(%{} = map), do: from_map(map)
    def load(_other), do: :error

    @impl true
    def dump(%Storehouse.File{} = file),
      do: {:ok, file |> Map.take(@fields) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)}

    def dump(_other), do: :error

    @impl true
    def embed_as(_format), do: :dump

    @impl true
    def equal?(%Storehouse.File{key: key, checksum: sum}, %Storehouse.File{
          key: key,
          checksum: sum
        }),
        do: true

    def equal?(a, b), do: a == b

    defp from_map(map) do
      fields =
        Map.new(@fields, fn field ->
          {field, Map.get(map, Atom.to_string(field), Map.get(map, field))}
        end)

      if is_binary(fields.key) and is_binary(fields.url) and is_binary(fields.content_type) and
           is_integer(fields.bytes),
         do:
           {:ok,
            struct!(Storehouse.File, %{fields | name: fields.name || Path.basename(fields.key)})},
         else: :error
    end
  end
end
