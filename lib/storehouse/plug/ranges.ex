defmodule Storehouse.Plug.Ranges do
  @moduledoc false
  # The `Range` of a request for a file: what Storehouse.Local.Plug and
  # Storehouse.Proxy send of it.

  @doc false
  # One `bytes` range: `first-last`, `first-` or `-suffix`. Anything else
  # (several ranges, another unit, a header that is not valid) is the whole
  # file, as RFC 9110 allows.
  def range([header], size) do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, String.trim(header), capture: :all_but_first) do
      ["", ""] -> :all
      ["", suffix] -> suffix_range(String.to_integer(suffix), size)
      [first, last] -> first_range(String.to_integer(first), last, size)
      nil -> :all
    end
  end

  def range(_headers, _size), do: :all

  defp suffix_range(0, _size), do: :unsatisfiable
  defp suffix_range(_suffix, 0), do: :unsatisfiable
  defp suffix_range(suffix, size), do: {max(size - suffix, 0), size - 1}

  defp first_range(first, _last, size) when first >= size, do: :unsatisfiable
  defp first_range(first, "", size), do: {first, size - 1}

  defp first_range(first, last, size) do
    case String.to_integer(last) do
      last when last < first -> :all
      last -> {first, min(last, size - 1)}
    end
  end
end
