defmodule Storehouse.Responsive do
  @moduledoc """
  What a page needs to show a photograph at every screen's size, from a
  preset of variants with a ladder of widths (`Storehouse.Variants`): its
  `src`, its `srcset`, its size, its placeholder. As data, for a JSON API,
  or as an `<img>` (`Storehouse.Components.img/1`).

      Storehouse.Responsive.resolve(file, :photo, sizes: "(min-width: 60rem) 60rem, 100vw")
      #=> %Storehouse.Responsive{
      #     src: "/variants/…/photo-2560-e04b77d1",
      #     srcset: "/variants/…/photo-640-… 640w, …, /variants/…/photo-2560-… 2400w",
      #     sizes: "(min-width: 60rem) 60rem, 100vw",
      #     width: 2400, height: 1600,
      #     placeholder: "data:image/webp;base64,…", color: "#9a7b76", …}

  The `srcset` has the ladder's widths below the original's, then the
  original's own (up to the widest step): never a size larger than the
  photograph. Each is asked for at its step of the ladder, or the next one
  up, so every photograph's sizes are the ladder's, and a CDN keeps few
  of them; a step past the original's width gives the original's. Its
  `width` and `height` are those of the largest, for the page to keep the
  room before the image arrives.

  It reads no store: the original's width and height are the file's
  (`Storehouse.store/2` keeps them), its placeholder and colour its
  analysis's (`Storehouse.Analyzer.Placeholder`, `ThumbHash`, `BlurHash`).
  It encodes as JSON (`JSON.Encoder`, `Jason.Encoder`).

  ## Warming

  A variant is made the first time it is asked for, and a large original
  takes seconds: `warm/3` asks for each size once, before the first
  visitor does, and `warm_later/3` does it out of the request, on the app's
  runner. Off unless the app turns it on, in production:

      config :storehouse, Storehouse.Responsive, warm: true
  """

  alias Storehouse.Jobs
  alias Storehouse.Variants

  defstruct [:src, :srcset, :sizes, :width, :height, :placeholder, :color, :thumbhash, :blurhash]

  @type t :: %__MODULE__{
          src: String.t(),
          srcset: String.t(),
          sizes: String.t() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          placeholder: String.t() | nil,
          color: String.t() | nil,
          thumbhash: String.t() | nil,
          blurhash: String.t() | nil
        }

  @accept "image/avif,image/webp,image/apng,*/*;q=0.8"
  @own [:src, :sizes, :up_to, :through, :accept, :base_url, :timeout, :enabled, :runner]

  @doc """
  The `src`, `srcset`, size and placeholder of `file` with `preset`.

  ## Options

    * `:src` - the width of `src`, for a browser that takes no `srcset`
      (the step of the ladder as wide, or the next one up). The default is
      the largest.
    * `:sizes` - the `sizes` attribute, as given: what the layout's slot
      for the photograph is, at each screen's width. See the Variants
      guide.
    * `Storehouse.Variants.url/3`'s, for each URL.
  """
  @spec resolve(Storehouse.File.t(), atom(), keyword()) :: t()
  def resolve(%Storehouse.File{} = file, preset, opts \\ []) do
    entries = widths(file, preset, opts)
    {largest, largest_step} = List.last(entries)
    src_step = if width = opts[:src], do: step(entries, width), else: largest_step
    {width, height} = size(file, Variants.preset_of(preset, opts), largest)
    placeholder = Storehouse.File.analyzed(file, "placeholder") || %{}

    %__MODULE__{
      src: url(file, preset, src_step, opts),
      srcset:
        Enum.map_join(entries, ", ", fn {w, step} -> "#{url(file, preset, step, opts)} #{w}w" end),
      sizes: opts[:sizes],
      width: width,
      height: height,
      placeholder: placeholder["placeholder"],
      color: placeholder["color"] || color(file),
      thumbhash: (Storehouse.File.analyzed(file, "thumbhash") || %{})["thumbhash"],
      blurhash: (Storehouse.File.analyzed(file, "blurhash") || %{})["blurhash"]
    }
  end

  @doc """
  The widths of `file`'s `srcset` with `preset`, each with the step of
  the ladder it is asked for at: `[{width, step}]`, narrowest first.

      # A photograph 1500 wide, a ladder of 640, 1280 and 1920:
      Storehouse.Responsive.widths(file, :photo)
      #=> [{640, 640}, {1280, 1280}, {1500, 1920}]

  For a file whose width is not known, the ladder's.
  """
  @spec widths(Storehouse.File.t(), atom(), keyword()) :: [{pos_integer(), pos_integer()}]
  def widths(%Storehouse.File{width: original}, preset, opts \\ []) do
    ladder = Variants.preset_of(preset, opts).widths
    widest = List.last(ladder)

    widths =
      if is_integer(original),
        do: Enum.filter(ladder, &(&1 < original)) ++ [min(original, widest)],
        else: ladder

    widths |> Enum.uniq() |> Enum.map(&{&1, Enum.find(ladder, widest, fn step -> step >= &1 end)})
  end

  @doc """
  Every URL `resolve/3` gives for `file` with `preset`, once each: the
  sizes to warm.

  ## Options

    * `:up_to` - the widest step: larger ones are left to be made when
      asked for (a lightbox's, zoomed in). The default is every one.
    * `:src`, and `Storehouse.Variants.url/3`'s, as for `resolve/3`.
  """
  @spec urls(Storehouse.File.t(), atom(), keyword()) :: [String.t()]
  def urls(%Storehouse.File{} = file, preset, opts \\ []) do
    file |> steps(preset, opts) |> Enum.map(&url(file, preset, &1, opts))
  end

  @doc """
  Makes `file`'s sizes with each of `presets` before a visitor asks for
  them: `{:ok, count}`, or `{:error, {:not_warmed, failed}}` with what was
  not made and why.

  With a renderer that renders in the app (`Storehouse.Renderer.Vix`),
  each is made with `Storehouse.variant/3`, in the format a browser of
  today is given. With one of URLs (`Storehouse.Renderer.Imgproxy`), each
  URL is asked for, as a browser of today asks: the service renders it and
  the CDN in front keeps it. One at a time, so the app's visitors never
  wait behind a batch.

  It warms when it is called, turned on or not.

  ## Options

    * `:up_to` and `:src` - as for `urls/2`.
    * `:through` - `:render` or `:http`. The default is the renderer's:
      `:http` asks a variant's URL, through the plug or a CDN, for a
      renderer in the app that is behind one.
    * `:accept` - the `Accept` header. The default is a browser's that
      takes AVIF and WebP.
    * `:base_url` - put before a URL that is a path, to ask it over HTTP:
      `"https://example.com"`.
    * `:timeout` - for each, in milliseconds. The default is 90 seconds.
    * `:adapter`, and `Storehouse.Variants`'s configuration.
  """
  @spec warm(Storehouse.File.t(), atom() | [atom()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, {:not_warmed, [{term(), term()}]}}
  def warm(%Storehouse.File{} = file, presets, opts \\ []) do
    through =
      Keyword.get_lazy(opts, :through, fn ->
        if Variants.renders?(opts), do: :render, else: :http
      end)

    targets =
      for preset <- List.wrap(presets), step <- steps(file, preset, opts), do: {preset, step}

    failed =
      Enum.flat_map(targets, fn {preset, step} = target ->
        case warm_one(file, preset, step, through, opts) do
          :ok -> []
          {:error, reason} -> [{target, reason}]
        end
      end)

    if failed == [], do: {:ok, length(targets)}, else: {:error, {:not_warmed, failed}}
  end

  @doc """
  `warm/3` out of the request, as a job of the app's runner, when warming
  is on (`enabled?/1`), and nothing when it is off. The original is not
  read: the file's width is all it needs. A file's job waiting is not
  queued again.

  On a queue of its own, so that the app's other work never waits behind
  it, with Oban:

      Storehouse.Responsive.warm_later(file, [:photo],
        up_to: 3840,
        runner: {Storehouse.Runner.Oban, queue: :warm}
      )

  ## Options

    * `:runner` - the runner, in place of the app's (`Storehouse.Runner`).
    * `:enabled` - in place of the configured `:warm`.
    * `warm/3`'s.
  """
  @spec warm_later(Storehouse.File.t(), atom() | [atom()], keyword()) :: :ok | {:error, term()}
  def warm_later(%Storehouse.File{} = file, presets, opts \\ []) do
    if enabled?(opts) do
      file
      |> Jobs.Warm.job(List.wrap(presets), Keyword.drop(opts, [:runner, :enabled]))
      |> Storehouse.Runner.enqueue(opts)
    else
      :ok
    end
  end

  @doc """
  Whether warming is on: `:enabled`, else the configured `:warm`, `false`
  by default, so that development and tests ask no image service.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get_lazy(opts, :enabled, fn ->
      Application.get_env(:storehouse, __MODULE__, []) |> Keyword.get(:warm, false)
    end) == true
  end

  defp warm_one(file, preset, step, :render, opts) do
    variant_opts =
      opts
      |> Keyword.drop(@own)
      |> Keyword.merge(width: step, accept: Keyword.get(opts, :accept, @accept))

    case Storehouse.variant(file, preset, variant_opts) do
      {:ok, _variant} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp warm_one(file, preset, step, :http, opts) do
    url = url(file, preset, step, opts)

    with {:ok, url} <- absolute(url, opts[:base_url]),
         do: get(url, Keyword.get(opts, :accept, @accept), Keyword.get(opts, :timeout, 90_000))
  end

  defp absolute("/" <> _ = path, nil), do: {:error, {:relative_url, path}}
  defp absolute("/" <> _ = path, base), do: {:ok, String.trim_trailing(base, "/") <> path}
  defp absolute(url, _base), do: {:ok, url}

  defp get(url, accept, timeout) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    http_opts = [
      timeout: timeout,
      connect_timeout: timeout,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    request = {String.to_charlist(url), [{~c"accept", String.to_charlist(accept)}]}

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} -> :ok
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The steps to warm, once each, `src`'s with them.
  defp steps(file, preset, opts) do
    entries = widths(file, preset, opts)
    src = if width = opts[:src], do: [step(entries, width)], else: []

    (src ++ Enum.map(entries, &elem(&1, 1)))
    |> Enum.uniq()
    |> Enum.filter(&(is_nil(opts[:up_to]) or &1 <= opts[:up_to]))
  end

  defp step(entries, width) do
    {_width, step} = Enum.find(entries, List.last(entries), fn {w, _step} -> w >= width end)
    step
  end

  defp url(file, preset, step, opts),
    do: Variants.url(file, preset, opts |> Keyword.drop(@own) |> Keyword.put(:width, step))

  # The size of the largest: the original's proportions, or the box's.
  defp size(_file, %{fit: :cover} = preset, largest), do: box(preset, largest)

  defp size(%Storehouse.File{width: w, height: h}, preset, largest)
       when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    {_box_width, box_height} = box(preset, largest)
    scale = Enum.min([1, largest / w | if(box_height, do: [box_height / h], else: [])])
    {round(w * scale), round(h * scale)}
  end

  defp size(_file, preset, largest), do: box(preset, largest)

  defp box(%{height: height, widths: [width]}, _largest) when is_integer(height),
    do: {width, height}

  defp box(%{aspect: {w, h}}, largest), do: {largest, round(largest * h / w)}
  defp box(_preset, largest), do: {largest, nil}

  defp color(file) do
    Enum.find_value(["thumbhash", "blurhash"], fn step ->
      (Storehouse.File.analyzed(file, step) || %{})["color"]
    end)
  end

  @doc false
  def to_map(%__MODULE__{} = responsive), do: Map.from_struct(responsive)

  if Code.ensure_loaded?(JSON.Encoder) do
    defimpl JSON.Encoder do
      def encode(responsive, encoder),
        do: JSON.Encoder.encode(Storehouse.Responsive.to_map(responsive), encoder)
    end
  end

  if Code.ensure_loaded?(Jason.Encoder) do
    defimpl Jason.Encoder do
      def encode(responsive, opts),
        do: Jason.Encode.map(Storehouse.Responsive.to_map(responsive), opts)
    end
  end
end
