defmodule Storehouse.Variants do
  @moduledoc """
  A file's other sizes and formats, by preset: a photograph's thumbnail,
  its sizes for a `srcset`, its WebP. Only the presets' sizes are ever
  made, so no one can have the server render at a size they choose.

      config :storehouse, Storehouse.Variants,
        presets: [
          thumb: [width: 320, height: 320, fit: :cover],
          photo: [widths: [640, 960, 1280, 1920, 2560], format: [:webp, :original]]
        ]

      Storehouse.variant_url(file, :thumb)
      #=> "/variants/2026/10/0b6…/harbour.jpg/thumb-320-5f3a91c2"
      Storehouse.variant_url(file, :photo, width: 1000)
      #=> "/variants/2026/10/0b6…/harbour.jpg/photo-1280-e04b77d1"

  What renders them is a `Storehouse.Renderer`: `Storehouse.Renderer.Vix`
  (libvips, in the app; the default when Vix is loaded), which stores each
  variant beside its original once, served by `Storehouse.Variants.Plug`;
  or `Storehouse.Renderer.Imgproxy`, whose URLs an imgproxy behind a CDN
  renders; or the app's own. See the Variants guide.

  ## Configuration

    * `:presets` - a keyword list of presets, by name (an atom of
      lowercase letters, digits and `_`). See "Presets".
    * `:renderer` - a module of `Storehouse.Renderer`, or
      `{module, options}`. The default is `Storehouse.Renderer.Vix`, when
      Vix is loaded.
    * `:url` - where `Storehouse.Variants.Plug` serves variants, for a
      renderer without URLs of its own. The default is `"/variants"`.
    * `:prefix` - the prefix of the stored variants' keys:
      `"<prefix><original key>/<preset>-<width>-<fingerprint>.<extension>"`,
      so deleting an original deletes its variants with one prefix. The
      default is `"variants/"`.
    * `:timeout` - how long a caller waits for a variant another is making,
      in milliseconds. The default is 60 seconds.

  Each can be given to a call, for an app with variants of several kinds.

  ## Presets

    * `:width` - the width, in pixels; or `:widths`, several, a ladder for
      a `srcset`. A width past the original's gives the original's: a
      variant is never enlarged.
    * `:height` - the height of the box, with `:width`; or `:aspect`,
      `{width, height}`, the box's proportions at every width. The default
      is any height.
    * `:fit` - `:inside` (the default: scaled to fit the box) or `:cover`
      (cropped to fill it, which needs a height).
    * `:focus` - what a crop keeps: `:centre` (the default), `:attention`,
      `:entropy` or `{x, y}`, a point in fractions from the top left.
    * `:format` - `:original` (the default: the original's, or JPEG for a
      format browsers do not show), `:webp`, `:jpeg`, `:png`, `:avif`,
      `:gif`; or a list, in order, of which the first the browser takes is
      given, by its `Accept`, the last to every browser: `[:webp, :original]`.
    * `:quality` - 1 to 100. The default is the renderer's.
    * `:profile` - `:srgb` (the default: converted to sRGB) or `:keep`
      (the photograph's colour profile kept, for wide-gamut screens).
    * `:metadata` - `:none` (the default: none of the original's EXIF,
      where it was taken least of all) or `:all`.
    * `:background` - `"#rrggbb"`, under transparency a format without it
      cannot keep. The default is white.
    * `:options` - a renderer's own options, by renderer:
      `options: [imgproxy: "sh:0.3"]`.

  A preset changed gives its variants new URLs and keys: a CDN's copy, kept
  for a year, is never of an older preset. The variants of the old one stay
  until their original is deleted, or the prefix is.
  """

  require Logger

  alias Storehouse.Variant

  @formats [:original, :webp, :jpeg, :png, :avif, :gif]
  @originals %{
    "image/webp" => :webp,
    "image/jpeg" => :jpeg,
    "image/png" => :png,
    "image/avif" => :avif,
    "image/gif" => :gif
  }
  @name ~r/\A[a-z0-9_]+\z/

  @doc """
  The URL of `file`'s variant of `preset`.

  ## Options

    * `:width` - the width wanted: the preset's that is as wide, or the
      next one up, or its widest. The default is its widest.
    * `:focus` - what a crop keeps, for this file (a photograph's own
      focus point): only with a renderer of URLs, which signs it.
    * The configuration's (`:presets`, `:renderer`, `:url`), for this call.
  """
  @spec url(Storehouse.File.t() | String.t(), atom(), keyword()) :: String.t()
  def url(file_or_key, preset, opts \\ []) do
    config = config(opts)
    file = file(file_or_key)
    {renderer, renderer_opts} = renderer!(config)
    variant = variant(file, preset!(config, preset), opts, :url)

    if exports?(renderer, :url, 3) do
      renderer.url(variant, file, renderer_opts)
    else
      if Keyword.has_key?(opts, :focus),
        do: raise(ArgumentError, ":focus is for a renderer of URLs, which signs it")

      plug_url(variant, config)
    end
  end

  @doc """
  `file`'s variant of `preset`, found or made: `{:ok, %Storehouse.File{}}`.

  Made once, however many ask for it at the same time, across a cluster's
  nodes: the first renders it, the others wait for it
  (`{:error, :timeout}` past `:timeout`). Made with a renderer that renders
  (`c:Storehouse.Renderer.render/4`); one of URLs only gives
  `{:error, :not_supported}`. A missing original gives `{:error, :enoent}`.

  Its `:width` and `:height` are known when it was made by this call.

  ## Options

    * `:width` - as for `url/3`.
    * `:accept` - the browser's `Accept` header, for a preset of several
      formats; or `:format`, one of them. The default is the last.
    * `:adapter` - the store, of the original and of its variants.
    * The configuration's, for this call.
  """
  @spec get(Storehouse.File.t() | String.t(), atom(), keyword()) ::
          {:ok, Storehouse.File.t()} | {:error, term()}
  def get(file_or_key, preset, opts \\ []) do
    config = config(opts)
    file = file(file_or_key)
    {renderer, renderer_opts} = renderer!(config)
    variant = variant(file, preset!(config, preset), opts, :render)
    key = key(variant, config)
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    meta = %{key: file.key, variant: key, preset: preset, width: variant.width}

    if exports?(renderer, :render, 4) do
      :telemetry.span([:storehouse, :variant], meta, fn ->
        {result, outcome} =
          told(found_or_made(file, variant, key, adapter, config, {renderer, renderer_opts}))

        {result, Map.put(meta, :result, outcome)}
      end)
    else
      {:error, :not_supported}
    end
  end

  # The stored variant; else made, once, and found again by every caller
  # that waited for it.
  defp found_or_made(file, variant, key, adapter, config, renderer) do
    with {:error, :enoent} <- found(key, adapter),
         do:
           once(key, config.timeout, fn -> unless_found(file, variant, key, adapter, renderer) end)
  end

  defp unless_found(file, variant, key, adapter, renderer) do
    with {:error, :enoent} <- found(key, adapter),
         do: made(file, variant, key, adapter, renderer)
  end

  defp told({:made, file}), do: {{:ok, file}, :made}
  defp told({:ok, file}), do: {{:ok, file}, :found}
  defp told(error), do: {error, :error}

  @doc """
  The prefix of the variants of the file with `key`, or of the files under
  a prefix: deleting it deletes them.
  """
  @spec prefix(String.t(), keyword()) :: String.t()
  def prefix(key, opts \\ []), do: under(config(opts).prefix, key)

  defp under(prefix, key), do: prefix <> key <> if(String.ends_with?(key, "/"), do: "", else: "/")

  @doc """
  The format of a preset's `formats` a browser is given, by its `Accept`
  header: the first it takes, else the last.

      iex> Storehouse.Variants.negotiate([:avif, :webp, :original], "image/webp,*/*")
      :webp
      iex> Storehouse.Variants.negotiate([:webp, :original], nil)
      :original
  """
  @spec negotiate([atom()], String.t() | nil) :: atom()
  def negotiate(formats, accept) do
    {preferred, [last]} = Enum.split(formats, -1)
    Enum.find(preferred, last, &accepts?(accept || "", &1))
  end

  # A browser that takes WebP or AVIF says so; every one takes the rest.
  defp accepts?(accept, :webp), do: String.contains?(accept, "image/webp")
  defp accepts?(accept, :avif), do: String.contains?(accept, "image/avif")
  defp accepts?(_accept, _format), do: true

  @doc false
  # Whether variants are stored: a preset, and a renderer that renders.
  def stored?(opts \\ []), do: stored(config(opts))

  defp stored(config) do
    case config.renderer do
      {renderer, _} -> config.presets != %{} and exports?(renderer, :render, 4)
      nil -> false
    end
  end

  @doc false
  # Deletes the variants under `key` or a prefix, when variants are stored
  # and the store lists files: an original deleted takes them with it. A
  # variant has none.
  def delete(key, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    config = config(opts)
    variant? = String.starts_with?(key, config.prefix)

    if not variant? and stored(config) and Storehouse.supports?(adapter, :list, 1) do
      case Storehouse.delete_prefix(under(config.prefix, key), adapter: adapter) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Storehouse: the variants of #{key} were not deleted: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  @doc false
  # The configuration, with the call's: presets by name, normalized.
  def config(opts) do
    config = Keyword.merge(Application.get_env(:storehouse, __MODULE__, []), opts)

    %{
      presets:
        Map.new(Keyword.get(config, :presets, []), fn {name, preset} ->
          {name, preset(name, preset)}
        end),
      renderer: renderer(Keyword.get_lazy(config, :renderer, &default_renderer/0)),
      url: config |> Keyword.get(:url, "/variants") |> String.trim_trailing("/"),
      prefix: Keyword.get(config, :prefix, "variants/"),
      timeout: Keyword.get(config, :timeout, 60_000)
    }
  end

  @doc false
  # The preset of a plug's request, its variant and the variant's current
  # fingerprint: `{:ok, preset, width}` or `:error`.
  def preset_for(config, name, width) do
    with {:ok, preset} <-
           Enum.find_value(config.presets, :error, fn {key, preset} ->
             Atom.to_string(key) == name and {:ok, preset}
           end),
         {width, ""} <- Integer.parse(width),
         true <- width in preset.widths do
      {:ok, preset, width}
    else
      _ -> :error
    end
  end

  @doc false
  def variant_for(file, preset, width, opts, purpose),
    do: variant(file(file), preset, Keyword.put(opts, :width, width), purpose)

  @doc false
  def plug_url(%Variant{} = variant, config),
    do:
      "#{config.url}/#{variant.source}/#{variant.preset}-#{variant.width}-#{variant.fingerprint}"

  @doc false
  # The stored key of a variant.
  def key(%Variant{} = variant, config) do
    under(config.prefix, variant.source) <>
      "#{variant.preset}-#{variant.width}-#{variant.fingerprint}.#{Variant.extension(variant.format)}"
  end

  @doc false
  def file(%Storehouse.File{} = file), do: file

  def file(key) when is_binary(key) do
    %Storehouse.File{
      key: key,
      url: "",
      name: Path.basename(key),
      bytes: 0,
      content_type: Storehouse.Check.content_type(Path.extname(key))
    }
  end

  defp renderer!(%{renderer: nil}),
    do: raise(ArgumentError, "no renderer of variants: add Vix, or configure :renderer")

  defp renderer!(%{renderer: renderer}), do: renderer

  defp renderer(nil), do: nil
  defp renderer({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp renderer(module) when is_atom(module), do: {module, []}

  defp default_renderer,
    do: if(Code.ensure_loaded?(Storehouse.Renderer.Vix), do: Storehouse.Renderer.Vix)

  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  @doc false
  # A preset, normalized: its `:widths`, `:height`, `:aspect`, `:fit` and the
  # rest, for `Storehouse.Responsive`.
  def preset_of(name, opts), do: preset!(config(opts), name)

  @doc false
  # Whether the configured renderer renders in the app.
  def renders?(opts) do
    {renderer, _opts} = renderer!(config(opts))
    exports?(renderer, :render, 4)
  end

  defp preset!(config, name) do
    case Map.fetch(config.presets, name) do
      {:ok, preset} -> preset
      :error -> raise ArgumentError, "no preset of variants #{inspect(name)}"
    end
  end

  # A preset, its options checked once.
  defp preset(name, opts) do
    unless is_atom(name) and Regex.match?(@name, Atom.to_string(name)),
      do:
        raise(ArgumentError, "a preset's name is an atom of a-z, 0-9 and _, not #{inspect(name)}")

    opts =
      Keyword.validate!(opts, [
        :width,
        :widths,
        :height,
        :aspect,
        :quality,
        :background,
        fit: :inside,
        focus: :centre,
        format: :original,
        profile: :srgb,
        metadata: :none,
        options: []
      ])

    preset = %{
      name: name,
      widths: widths(name, opts[:width], opts[:widths]),
      height: opts[:height],
      aspect: opts[:aspect],
      fit: opts[:fit],
      focus: opts[:focus],
      formats: List.wrap(opts[:format]),
      quality: opts[:quality],
      profile: opts[:profile],
      metadata: opts[:metadata],
      background: opts[:background],
      options: opts[:options]
    }

    check!(preset)
    preset
  end

  defp widths(_name, width, nil) when is_integer(width) and width > 0, do: [width]

  defp widths(name, nil, [_ | _] = widths) do
    if Enum.all?(widths, &(is_integer(&1) and &1 > 0)),
      do: widths |> Enum.uniq() |> Enum.sort(),
      else: raise(ArgumentError, "preset #{inspect(name)}: :widths are positive integers")
  end

  defp widths(name, _width, _widths),
    do:
      raise(
        ArgumentError,
        "preset #{inspect(name)} needs :width or :widths, a positive integer or a list of them"
      )

  @checks [
    :height,
    :aspect,
    :fit,
    :focus,
    :format,
    :quality,
    :profile,
    :metadata,
    :background,
    :options
  ]

  defp check!(preset) do
    for field <- @checks do
      with {:error, message} <- check(field, preset),
           do: raise(ArgumentError, "preset #{inspect(preset.name)}: #{message}")
    end
  end

  defp check(:height, %{height: nil}), do: :ok
  defp check(:height, %{height: h, widths: [_]}) when is_integer(h) and h > 0, do: :ok

  defp check(:height, %{height: h}) when is_integer(h) and h > 0,
    do: {:error, ":height is for one :width; give :aspect"}

  defp check(:height, _preset), do: {:error, ":height is a positive integer"}

  defp check(:aspect, %{aspect: nil}), do: :ok

  defp check(:aspect, %{height: height}) when height != nil,
    do: {:error, ":height or :aspect, not both"}

  defp check(:aspect, %{aspect: {w, h}}) when is_integer(w) and is_integer(h) and w > 0 and h > 0,
    do: :ok

  defp check(:aspect, _preset), do: {:error, ":aspect is {width, height}"}

  defp check(:fit, %{fit: :inside}), do: :ok

  defp check(:fit, %{fit: :cover, height: nil, aspect: nil}),
    do: {:error, ":cover needs :height or :aspect"}

  defp check(:fit, %{fit: :cover}), do: :ok
  defp check(:fit, _preset), do: {:error, ":fit is :inside or :cover"}

  defp check(:focus, %{focus: focus}), do: focus(focus)

  defp check(:format, %{formats: formats}) do
    if formats != [] and Enum.all?(formats, &(&1 in @formats)),
      do: :ok,
      else: {:error, ":format is one of #{inspect(@formats)}, or a list of them"}
  end

  defp check(:quality, %{quality: nil}), do: :ok
  defp check(:quality, %{quality: q}) when is_integer(q) and q >= 1 and q <= 100, do: :ok
  defp check(:quality, _preset), do: {:error, ":quality is 1 to 100"}

  defp check(:profile, %{profile: profile}) when profile in [:srgb, :keep], do: :ok
  defp check(:profile, _preset), do: {:error, ":profile is :srgb or :keep"}

  defp check(:metadata, %{metadata: metadata}) when metadata in [:none, :all], do: :ok
  defp check(:metadata, _preset), do: {:error, ":metadata is :none or :all"}

  defp check(:background, %{background: nil}), do: :ok

  defp check(:background, %{background: background}) do
    if is_binary(background) and Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, background),
      do: :ok,
      else: {:error, ":background is \"#rrggbb\""}
  end

  defp check(:options, %{options: options}) do
    if Keyword.keyword?(options), do: :ok, else: {:error, ":options is a keyword list"}
  end

  defp focus(focus) when focus in [:centre, :attention, :entropy], do: :ok
  defp focus({x, y}) when x >= 0 and x <= 1 and y >= 0 and y <= 1, do: :ok

  defp focus(_focus),
    do: {:error, ":focus is :centre, :attention, :entropy or {x, y}, fractions from 0 to 1"}

  # The variant a call asks for: for a URL, its formats (a list, chosen by
  # the browser) or its one; for rendering, the one it is made in.
  defp variant(file, preset, opts, purpose) do
    width = step(preset.widths, Keyword.get(opts, :width))
    focus = Keyword.get(opts, :focus, preset.focus)
    with {:error, message} <- focus(focus), do: raise(ArgumentError, message)

    format =
      cond do
        purpose == :url and length(preset.formats) > 1 -> preset.formats
        purpose == :url -> hd(preset.formats)
        format = Keyword.get(opts, :format) -> chosen(format, preset, file)
        true -> preset.formats |> negotiate(Keyword.get(opts, :accept)) |> format(file)
      end

    variant = %Variant{
      source: file.key,
      preset: preset.name,
      width: width,
      height: height(preset, width),
      fit: preset.fit,
      focus: focus,
      format: format,
      quality: preset.quality,
      profile: preset.profile,
      metadata: preset.metadata,
      background: preset.background,
      options: preset.options,
      fingerprint: ""
    }

    %{variant | fingerprint: fingerprint(variant, preset)}
  end

  defp chosen(format, preset, file) do
    if format in preset.formats or format in Enum.map(preset.formats, &format(&1, file)),
      do: format(format, file),
      else: raise(ArgumentError, "preset #{inspect(preset.name)} has no #{inspect(format)}")
  end

  defp step(widths, nil), do: List.last(widths)

  defp step(widths, width) when is_integer(width),
    do: Enum.find(widths, List.last(widths), &(&1 >= width))

  defp height(%{height: height}, _width) when is_integer(height), do: height
  defp height(%{aspect: {w, h}}, width), do: round(width * h / w)
  defp height(_preset, _width), do: nil

  # An original's format, where browsers show it; JPEG for the rest (TIFF,
  # HEIC, a camera's raw).
  defp format(:original, file), do: Map.get(@originals, file.content_type, :jpeg)
  defp format(format, _file), do: format

  # Eight hex digits of what makes the image, the preset's formats (not the
  # one chosen, which the key has) among them.
  defp fingerprint(variant, preset) do
    made =
      Enum.map_join(
        [
          variant.width,
          variant.height,
          variant.fit,
          inspect(variant.focus),
          Enum.join(preset.formats, ","),
          variant.quality,
          variant.profile,
          variant.metadata,
          variant.background,
          inspect(Enum.sort(variant.options))
        ],
        ";",
        &to_string/1
      )

    :sha256 |> :crypto.hash(made) |> binary_part(0, 4) |> Base.encode16(case: :lower)
  end

  # The stored variant, as a file.
  defp found(key, adapter) do
    with {:ok, head} <- adapter.head(key) do
      {:ok,
       %Storehouse.File{
         key: key,
         url: adapter.url(key),
         name: Path.basename(key),
         bytes: head.bytes,
         content_type: Storehouse.Check.content_type(Path.extname(key)),
         checksum: head.checksum
       }}
    end
  end

  # Downloads the original, renders it and stores the variant.
  defp made(file, variant, key, adapter, {renderer, renderer_opts}) do
    base =
      Path.join(System.tmp_dir!(), "storehouse-variant-#{System.unique_integer([:positive])}")

    source = base <> "-original" <> Path.extname(file.key)
    destination = base <> "." <> Variant.extension(variant.format)

    try do
      with :ok <- Storehouse.download(file.key, source, adapter: adapter),
           :ok <- renderer.render(source, destination, variant, renderer_opts),
           {:ok, description} <-
             Storehouse.Check.describe(destination, Variant.content_type(variant.format), []),
           meta = %{
             name: Path.basename(key),
             content_type: Variant.content_type(variant.format),
             bytes: description.bytes,
             checksum: Storehouse.checksum(destination)
           },
           {:ok, url} <- adapter.put(key, destination, meta) do
        {:made,
         %Storehouse.File{
           key: key,
           url: url,
           name: meta.name,
           bytes: meta.bytes,
           content_type: meta.content_type,
           width: description.width,
           height: description.height,
           checksum: meta.checksum
         }}
      end
    after
      File.rm(source)
      File.rm(destination)
    end
  end

  # `fun` once across the cluster's nodes, however many call it at the same
  # time: run by a process registered under the key in `:global`, which
  # every caller monitors and whose exit gives them its result.
  defp once(key, timeout, fun) do
    name = {__MODULE__, key}
    pid = with :undefined <- :global.whereis_name(name), do: worker(name, fun)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> outcome(reason, key, timeout, fun)
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  # Another registered it first, or it was done before it was watched:
  # the next call finds the other, or the variant.
  defp outcome({:shutdown, :taken}, key, timeout, fun), do: once(key, timeout, fun)
  defp outcome(:noproc, key, timeout, fun), do: once(key, timeout, fun)
  defp outcome({:shutdown, {:done, result}}, _key, _timeout, _fun), do: result

  defp outcome({exception, _stack}, _key, _timeout, _fun) when is_exception(exception),
    do: {:error, Exception.message(exception)}

  defp outcome(reason, _key, _timeout, _fun), do: {:error, reason}

  # Out of the caller, so a caller that stops waiting stops nothing, with
  # its callers for a store that needs them (Storehouse.Memory).
  defp worker(name, fun) do
    callers = [self() | Process.get(:"$callers", [])]

    spawn(fn ->
      Process.put(:"$callers", callers)

      case :global.register_name(name, self()) do
        :yes -> exit({:shutdown, {:done, fun.()}})
        :no -> exit({:shutdown, :taken})
      end
    end)
  end
end
