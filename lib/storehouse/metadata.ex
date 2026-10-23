defmodule Storehouse.Metadata do
  @moduledoc """
  A file's own metadata (`Storehouse.File`'s `:metadata`): a map the app
  keeps with the file, in its record's column and in the JSON it sends,
  of what a person entered (a caption, a credit, a description for
  readers who cannot see it) and what the app decided.

  It holds what JSON holds, so that it goes into a `jsonb` column and a
  response as it is: string keys; strings (UTF-8, with no NUL byte, which
  PostgreSQL's `jsonb` cannot keep), numbers, booleans and `nil`; lists
  and maps of them. `normalize/1` turns atoms (keys and values) into
  strings, and dates and times into ISO 8601 strings; anything else is refused, with where it
  is.

  The key `"analyzed"` is the analysis's (what was read from the file: its
  EXIF, a placeholder): each step writes its own part of it
  (`Storehouse.File.put_analyzed/3`), and `Storehouse.File.put_metadata/2`
  never writes it, so analysis never overwrites what a person entered, nor
  the other way round.
  """

  @max_depth 8
  @max_bytes 65_536

  @typedoc "Where a value that is refused is: the keys and indexes down to it."
  @type path :: [String.t() | non_neg_integer()]

  @doc """
  Metadata as `Storehouse.File` keeps it, or `{:error, {:invalid_metadata,
  path}}` with where the first value it refuses is. At most #{@max_depth}
  levels deep, and #{@max_bytes} bytes of JSON.

  ## Examples

      iex> Storehouse.Metadata.normalize(%{caption: "The quay", rating: 4, taken: ~D[2026-10-01]})
      {:ok, %{"caption" => "The quay", "rating" => 4, "taken" => "2026-10-01"}}

      iex> Storehouse.Metadata.normalize(%{"gear" => %{"lens" => {35, :mm}}})
      {:error, {:invalid_metadata, ["gear", "lens"]}}

      iex> Storehouse.Metadata.normalize(%{"title" => "a\\0b"})
      {:error, {:invalid_metadata, ["title"]}}

  """
  @spec normalize(map()) :: {:ok, map()} | {:error, {:invalid_metadata, path()}}
  def normalize(metadata) when is_map(metadata) and not is_struct(metadata) do
    with {:ok, normalized} <- value(metadata, [], 0) do
      if IO.iodata_length(JSON.encode_to_iodata!(normalized)) <= @max_bytes,
        do: {:ok, normalized},
        else: {:error, {:invalid_metadata, []}}
    end
  end

  def normalize(_metadata), do: {:error, {:invalid_metadata, []}}

  defp value(_value, path, depth) when depth > @max_depth, do: refused(path)
  defp value(nil, _path, _depth), do: {:ok, nil}
  defp value(boolean, _path, _depth) when is_boolean(boolean), do: {:ok, boolean}
  defp value(number, _path, _depth) when is_number(number), do: {:ok, number}
  defp value(atom, _path, _depth) when is_atom(atom), do: {:ok, Atom.to_string(atom)}

  defp value(string, path, _depth) when is_binary(string) do
    if String.valid?(string) and not String.contains?(string, <<0>>),
      do: {:ok, string},
      else: refused(path)
  end

  defp value(%module{} = at, _path, _depth) when module in [Date, Time, DateTime, NaiveDateTime],
    do: {:ok, module.to_iso8601(at)}

  defp value(map, path, depth) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, inner}, {:ok, acc} ->
      with {:ok, key} <- key(key, path),
           {:ok, inner} <- value(inner, path ++ [key], depth + 1) do
        {:cont, {:ok, Map.put(acc, key, inner)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp value(list, path, depth) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {inner, index}, {:ok, acc} ->
      case value(inner, path ++ [index], depth + 1) do
        {:ok, inner} -> {:cont, {:ok, [inner | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end)
  end

  defp value(_other, path, _depth), do: refused(path)

  defp key(key, path) when is_atom(key) and key not in [nil, true, false],
    do: key(Atom.to_string(key), path)

  defp key(key, path) when is_binary(key) do
    if key != "" and String.valid?(key) and not String.contains?(key, <<0>>),
      do: {:ok, key},
      else: refused(path ++ [key])
  end

  defp key(key, path), do: refused(path ++ [inspect(key)])

  defp refused(path), do: {:error, {:invalid_metadata, path}}

  @doc """
  `into` with `from` merged in: maps merged key by key, all the way down;
  any other value, `nil` too, replaced.

  ## Examples

      iex> Storehouse.Metadata.merge(%{"credit" => %{"name" => "Ana", "year" => 2025}}, %{"credit" => %{"year" => 2026}})
      %{"credit" => %{"name" => "Ana", "year" => 2026}}

  """
  @spec merge(map(), map()) :: map()
  def merge(into, from) when is_map(into) and is_map(from) do
    Map.merge(into, from, fn
      _key, %{} = left, %{} = right -> merge(left, right)
      _key, _left, right -> right
    end)
  end
end
