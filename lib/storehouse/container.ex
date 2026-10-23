defmodule Storehouse.Container do
  @moduledoc false
  # What the metadata editors of chunked formats (`Storehouse.PNG`,
  # `Storehouse.WebP`) share: a file read a chunk at a time, the chunks
  # that hold the image copied by their place in it, never read into
  # memory, and the new file written from the parts.

  @typedoc "Bytes, or where they are in the file read: `{offset, size}`."
  @type part :: iodata() | {non_neg_integer(), non_neg_integer()}

  @doc """
  `fun`'s result with the file at `from` open, or `{:error, posix}` when
  it cannot be opened.
  """
  def open(from, fun) do
    case File.open(from, [:read, :raw, :binary, :read_ahead], fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Exactly `size` bytes, or `:error` before the file's end."
  def read_exact(_io, 0), do: {:ok, ""}

  def read_exact(io, size) do
    case :file.read(io, size) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _short -> :error
    end
  end

  @doc "Moves past `size` bytes, or `:error` when the file has fewer."
  def skip(io, at, size, file_size) do
    if at + size <= file_size do
      {:ok, _at} = :file.position(io, at + size)
      :ok
    else
      :error
    end
  end

  @doc """
  The file at `to`, from the parts, nested as iodata is: bytes as they
  are, places copied from `input`.
  """
  def write(to, input, parts) do
    # Bytes and places, nested as the formats build them: each run of
    # bytes written at once, each place copied.
    parts =
      parts
      |> List.wrap()
      |> List.flatten()
      |> Enum.chunk_by(&is_tuple/1)
      |> Enum.flat_map(fn
        [{_at, _size} | _places] = places -> joined(places)
        bytes -> [bytes]
      end)

    File.open(to, [:write, :raw, :binary], &write_parts(&1, input, parts))
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_parts(output, input, parts) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case write_part(output, input, part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Places one after the other in the file, copied at once: a PNG's image
  # is in many chunks.
  defp joined(places) do
    places
    |> Enum.reduce([], fn
      {at, size}, [{last, length} | rest] when last + length == at ->
        [{last, length + size} | rest]

      place, acc ->
        [place | acc]
    end)
    |> Enum.reverse()
  end

  defp write_part(output, input, {at, size}) when is_integer(at) do
    with {:ok, ^at} <- :file.position(input, at),
         {:ok, ^size} <- :file.copy(input, output, size),
         do: :ok
  end

  defp write_part(output, _input, bytes), do: :file.write(output, bytes)
end
