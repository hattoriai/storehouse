defmodule Storehouse.Image.BlurHash do
  @moduledoc """
  [BlurHash](https://blurha.sh): an image's placeholder as a short string,
  20 to 30 characters, for a page to decode into a blur (`blurhash` on
  npm, and ports in most languages). The same string as its reference
  implementation, from the image's pixels: `Storehouse.Analyzer.BlurHash`
  gives it from a stored file.
  """

  @characters ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
              |> List.to_tuple()

  @doc """
  The BlurHash of an image of `width` × `height` pixels, given as RGB,
  eight bits a band, row by row, with `x` × `y` components (1 to 9 each):
  more is more detail, and a longer string. Most use 4 × 3.

      iex> red = :binary.copy(<<255, 0, 0>>, 4)
      iex> Storehouse.Image.BlurHash.encode(2, 2, red, 4, 3)
      "L~TI:j|cfQ|c|c|cfQ|cfQfQfQfQ"
  """
  @spec encode(pos_integer(), pos_integer(), binary(), 1..9, 1..9) :: String.t()
  def encode(width, height, rgb, x, y)
      when x in 1..9 and y in 1..9 and byte_size(rgb) == width * height * 3 do
    linear =
      for <<r, g, b <- rgb>>, into: [], do: {to_linear(r), to_linear(g), to_linear(b)}

    rows = linear |> Enum.chunk_every(width) |> Enum.with_index()
    [dc | ac] = for cy <- 0..(y - 1), cx <- 0..(x - 1), do: factor(rows, width, height, cx, cy)

    {maximum, quantised} =
      case ac do
        [] ->
          {1, 0}

        _ac ->
          actual = ac |> Enum.flat_map(&Tuple.to_list/1) |> Enum.map(&abs/1) |> Enum.max()
          quantised = floor(max(0, min(82, floor(actual * 166 - 0.5))))
          {(quantised + 1) / 166, quantised}
      end

    IO.iodata_to_binary([
      base83(x - 1 + (y - 1) * 9, 1),
      base83(quantised, 1),
      base83(dc(dc), 4),
      Enum.map(ac, &base83(ac(&1, maximum), 2))
    ])
  end

  defp factor(rows, width, height, cx, cy) do
    normalisation = if cx == 0 and cy == 0, do: 1, else: 2

    {r, g, b} =
      Enum.reduce(rows, {0, 0, 0}, fn {row, py}, sums ->
        fy = :math.cos(:math.pi() * cy * py / height)

        row
        |> Enum.with_index()
        |> Enum.reduce(sums, fn {{r, g, b}, px}, {sr, sg, sb} ->
          basis = normalisation * :math.cos(:math.pi() * cx * px / width) * fy
          {sr + basis * r, sg + basis * g, sb + basis * b}
        end)
      end)

    scale = 1 / (width * height)
    {r * scale, g * scale, b * scale}
  end

  defp dc({r, g, b}), do: to_srgb(r) * 65_536 + to_srgb(g) * 256 + to_srgb(b)

  defp ac({r, g, b}, maximum) do
    quant = fn v -> floor(max(0, min(18, floor(sign_pow(v / maximum, 0.5) * 9 + 9.5)))) end
    quant.(r) * 19 * 19 + quant.(g) * 19 + quant.(b)
  end

  defp to_linear(value) do
    v = value / 255
    if v <= 0.04045, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
  end

  defp to_srgb(value) do
    v = value |> max(0) |> min(1)

    if v <= 0.0031308,
      do: trunc(v * 12.92 * 255 + 0.5),
      else: trunc((1.055 * :math.pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
  end

  defp sign_pow(value, exponent) when value < 0, do: -:math.pow(-value, exponent)
  defp sign_pow(value, exponent), do: :math.pow(value, exponent)

  defp base83(value, length) do
    for i <- 1..length do
      digit = value |> div(Integer.pow(83, length - i)) |> rem(83)
      elem(@characters, digit)
    end
  end
end
