defmodule Storehouse.Batch do
  @moduledoc """
  Uploads straight to the store, many at a time: what a frontend that is
  not a LiveView (React, Vue, a native app) asks of the app around the
  browser's `PUT`s. `presign/2` signs a batch, `register/2` checks the
  files once they are there. `Storehouse.Plug.Presign` and
  `Storehouse.Plug.Register` answer them in JSON.

  Each gives one result per item, in order: some files are refused (their
  type, their size, the room left) and the others go ahead.

    * `{:ok, upload}` - `presign/2`: signed (`Storehouse.presign_upload/4`).
    * `{:ok, file}` - `register/2`: checked, a `Storehouse.File`.
    * `{:existing, file}` - a file the app has already (`:existing`):
      nothing to upload, nothing kept twice.
    * `{:error, code}` - an atom the frontend translates: `:not_accepted`,
      `:too_large`, `:storage_full`, `:invalid_checksum`, `:not_owner`,
      `:invalid_item`, `:too_many`, or the store's.

  ## The room

  `:room` is shared by the batch: each file presigned (or registered)
  takes its size from what the next one sees, so ten files that fit one
  at a time but not together are not all signed. A file the app has
  already takes none.
  """

  @max_items 100

  @doc "The most items a batch takes, by default."
  @spec max_items() :: pos_integer()
  def max_items, do: @max_items

  @doc """
  Signs uploads of `items`, each a map with `"name"`, `"type"`, `"bytes"`
  and, optionally, `"checksum"` (the SHA-256 the browser read, hex or
  Base64). String or atom keys.

  Takes the options of `Storehouse.presign_upload/4` (`:accept`,
  `:max_bytes`, `:owner`, `:existing`, `:key`, `:cache`, `:expires_in`,
  `:adapter`), with `:room` shared by the batch, and `:max_items`
  (`#{@max_items}`): a larger batch gives `{:error, :too_many}`.
  """
  @spec presign([map()], keyword()) :: {:ok, [tuple()]} | {:error, :too_many}
  def presign(items, opts \\ []) when is_list(items) do
    with :ok <- at_most(items, opts) do
      {results, _room} =
        Enum.map_reduce(items, Keyword.get(opts, :room, :infinity), &presign_next(&1, &2, opts))

      {:ok, results}
    end
  end

  # An item signed in the room left, and the room left for the next.
  defp presign_next(item, room, opts) do
    case presign_item(item, Keyword.put(opts, :room, room)) do
      {:ok, upload} -> {{:ok, upload}, take(room, field(item, :bytes))}
      other -> {other, room}
    end
  end

  defp presign_item(item, opts) do
    with name when is_binary(name) <- field(item, :name),
         type when is_binary(type) or is_nil(type) <- field(item, :type),
         bytes when is_integer(bytes) and bytes >= 0 <- field(item, :bytes),
         checksum when is_binary(checksum) or is_nil(checksum) <- field(item, :checksum) do
      opts = if checksum, do: Keyword.put(opts, :checksum, checksum), else: opts
      Storehouse.presign_upload(name, type, bytes, opts)
    else
      _invalid -> {:error, :invalid_item}
    end
  end

  @doc """
  Checks the files a browser uploaded (`Storehouse.verify_upload/2`):
  `items` are maps with `"key"` (the one `presign/2` gave) and,
  optionally, `"name"`. The key of another owner's file is refused with
  `:not_owner` and left as it is, with `:owner`. Two files of the same
  bytes in one batch are one: the second gives `{:existing, first}`, and
  its copy is deleted.

  Takes the options of `Storehouse.verify_upload/2` (`:accept`,
  `:max_bytes`, `:max_pixels`, `:owner`, `:existing`, `:metadata`,
  `:adapter`), with `:room` shared by the batch (the sizes the store
  gives), and `:max_items`.
  """
  @spec register([map()], keyword()) :: {:ok, [tuple()]} | {:error, :too_many}
  def register(items, opts \\ []) when is_list(items) do
    with :ok <- at_most(items, opts) do
      start = {Keyword.get(opts, :room, :infinity), %{}}
      {results, _acc} = Enum.map_reduce(items, start, &register_next(&1, &2, opts))
      {:ok, results}
    end
  end

  # An item checked in the room left, then the room left and the files seen
  # for the next: the batch's own files count as the app's, so the same
  # bytes twice in it are one.
  defp register_next(item, {room, seen}, opts) do
    existing = Keyword.get(opts, :existing, fn _checksum -> nil end)
    known = fn checksum -> Map.get(seen, checksum) || existing.(checksum) end

    case register_item(item, Keyword.merge(opts, room: room, existing: known)) do
      {:ok, file} -> {{:ok, file}, {take(room, file.bytes), remember(seen, file)}}
      other -> {other, {room, seen}}
    end
  end

  defp register_item(item, opts) do
    with key when is_binary(key) <- field(item, :key),
         name when is_binary(name) or is_nil(name) <- field(item, :name) do
      opts = if name, do: Keyword.put(opts, :name, name), else: opts
      Storehouse.verify_upload(key, opts)
    else
      _invalid -> {:error, :invalid_item}
    end
  end

  defp remember(seen, %Storehouse.File{checksum: nil}), do: seen

  defp remember(seen, %Storehouse.File{checksum: checksum} = file),
    do: Map.put(seen, checksum, file)

  defp at_most(items, opts) do
    if length(items) <= Keyword.get(opts, :max_items, @max_items),
      do: :ok,
      else: {:error, :too_many}
  end

  defp take(:infinity, _bytes), do: :infinity
  defp take(room, bytes) when is_integer(room) and is_integer(bytes), do: room - bytes
  defp take(room, _bytes), do: room

  defp field(item, name) when is_map(item),
    do: Map.get(item, Atom.to_string(name), Map.get(item, name))

  defp field(_item, _name), do: nil
end
