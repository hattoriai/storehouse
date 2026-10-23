defmodule Storehouse.ThumbHash do
  @moduledoc """
  [ThumbHash](https://evanw.github.io/thumbhash/): an image's placeholder
  in about 25 bytes, its colours, its proportions and its transparency, for
  a page to decode into a blur (`thumbhash` on npm, and ports in most
  languages). The same bytes as its reference implementation, from the
  image's pixels: `Storehouse.Analyzer.ThumbHash` gives them from a stored
  file.
  """

  import Bitwise

  @doc """
  The ThumbHash of an image of `width` × `height` pixels, at most 100 each,
  given as RGBA, eight bits a band, row by row.

      iex> red = :binary.copy(<<255, 0, 0, 255>>, 4)
      iex> Storehouse.ThumbHash.encode(2, 2, red) |> Base.encode64()
      "1fsrBwB4CIeIiIiHiIiICIiH6OAIDo4A"
  """
  @spec encode(pos_integer(), pos_integer(), binary()) :: binary()
  def encode(width, height, rgba)
      when width in 1..100 and height in 1..100 and byte_size(rgba) == width * height * 4 do
    pixels = for <<r, g, b, a <- rgba>>, do: {r / 255, g / 255, b / 255, a / 255}
    {avg_r, avg_g, avg_b, avg_a} = average(pixels)

    alpha? = avg_a < width * height
    limit = if alpha?, do: 5, else: 7
    longest = max(width, height)
    lx = max(1, round_js(limit * width / longest))
    ly = max(1, round_js(limit * height / longest))

    # Each pixel laid on the average colour, as luminance, yellow-blue,
    # red-green and alpha.
    lpqa =
      Enum.map(pixels, fn {r, g, b, a} ->
        r = avg_r * (1 - a) + a * r
        g = avg_g * (1 - a) + a * g
        b = avg_b * (1 - a) + a * b
        {(r + g + b) / 3, (r + g) / 2 - b, r - g, a}
      end)

    channel = fn n -> lpqa |> Enum.map(&elem(&1, n)) |> List.to_tuple() end
    {l_dc, l_ac, l_scale} = dct(channel.(0), width, height, max(3, lx), max(3, ly))
    {p_dc, p_ac, p_scale} = dct(channel.(1), width, height, 3, 3)
    {q_dc, q_ac, q_scale} = dct(channel.(2), width, height, 3, 3)
    landscape? = width > height

    header24 =
      round_js(63 * l_dc) ||| round_js(31.5 + 31.5 * p_dc) <<< 6 |||
        round_js(31.5 + 31.5 * q_dc) <<< 12 ||| round_js(31 * l_scale) <<< 18 |||
        bit(alpha?) <<< 23

    header16 =
      if(landscape?, do: ly, else: lx) ||| round_js(63 * p_scale) <<< 3 |||
        round_js(63 * q_scale) <<< 9 ||| bit(landscape?) <<< 15

    {alpha_byte, acs} =
      if alpha? do
        {a_dc, a_ac, a_scale} = dct(channel.(3), width, height, 5, 5)
        {<<round_js(15 * a_dc) ||| round_js(15 * a_scale) <<< 4>>, [l_ac, p_ac, q_ac, a_ac]}
      else
        {<<>>, [l_ac, p_ac, q_ac]}
      end

    <<header24::little-24, header16::little-16>> <> alpha_byte <> nibbles(List.flatten(acs))
  end

  defp average(pixels) do
    {r, g, b, a} =
      Enum.reduce(pixels, {0, 0, 0, 0}, fn {r, g, b, a}, {sr, sg, sb, sa} ->
        {sr + a * r, sg + a * g, sb + a * b, sa + a}
      end)

    if a > 0, do: {r / a, g / a, b / a, a}, else: {r, g, b, a}
  end

  # The constant term, and the varying ones from 0 to 1, with their scale.
  defp dct(channel, width, height, nx, ny) do
    terms =
      for cy <- 0..(ny - 1),
          cx <- 0..(nx - 1),
          cx * ny < nx * (ny - cy) do
        term(channel, width, height, cx, cy)
      end

    [dc | ac] = terms
    scale = ac |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)
    ac = if scale > 0, do: Enum.map(ac, &(0.5 + 0.5 / scale * &1)), else: ac
    {dc, ac, scale}
  end

  # One term of the cosine transform: the channel's sum against its cosines.
  defp term(channel, width, height, cx, cy) do
    fx = for x <- 0..(width - 1), do: :math.cos(:math.pi() / width * cx * (x + 0.5))

    sum =
      Enum.reduce(0..(height - 1), 0, fn y, sum ->
        fy = :math.cos(:math.pi() / height * cy * (y + 0.5))
        row(channel, fx, y * width, fy, sum)
      end)

    sum / (width * height)
  end

  defp row(channel, fx, start, fy, sum) do
    fx
    |> Enum.with_index()
    |> Enum.reduce(sum, fn {fx, x}, sum -> sum + elem(channel, start + x) * fx * fy end)
  end

  # The varying terms, four bits each, the first of each pair low.
  defp nibbles(terms) do
    terms
    |> Enum.map(&round_js(15 * &1))
    |> Enum.chunk_every(2, 2, [0])
    |> Enum.map(fn [low, high] -> low ||| high <<< 4 end)
    |> :erlang.list_to_binary()
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  # JavaScript's Math.round, as the reference rounds: half up.
  defp round_js(value), do: floor(value + 0.5)
end
