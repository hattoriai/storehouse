defmodule Storehouse.Renderer.Imgproxy do
  @moduledoc """
  The URLs of variants [imgproxy](https://imgproxy.net) renders
  (`Storehouse.Renderer`): signed, so only the presets' sizes are ever
  rendered, and the same every time, for a CDN in front of it to keep.
  The app renders nothing, and stores nothing.

      config :storehouse, Storehouse.Variants,
        renderer:
          {Storehouse.Renderer.Imgproxy,
           url: "https://images.example.com",
           key: System.fetch_env!("IMGPROXY_KEY"),
           salt: System.fetch_env!("IMGPROXY_SALT"),
           source: "s3://my-bucket/"},
        presets: [photo: [widths: [640, 1280, 1920], format: [:webp, :original]]]

  A preset is written as imgproxy's processing options:

    * a width alone is `w:<width>`; a box, `rs:fit:<width>:<height>`, or
      `rs:fill:<width>:<height>` with `fit: :cover` and its gravity
      (`g:ce`, `g:sm` for `:attention` and `:entropy`, `g:fp:<x>:<y>`);
    * `q:<quality>`, when the preset gives one;
    * `f:<format>` for one format; none for `:original`, or for several,
      which imgproxy chooses itself by `Accept` (with
      `IMGPROXY_AUTO_WEBP` or `IMGPROXY_AUTO_AVIF` on);
    * `scp:0` for `profile: :keep`, `sm:0` for `metadata: :all` (imgproxy
      strips metadata by default), a background as `bg:<hex>`;
    * then the preset's `options: [imgproxy: "…"]`, as they are:
      `"sh:0.3/fq:webp:86:jpeg:90"`.

  imgproxy never enlarges an image unless it is told to.

  ## Options

    * `:url` - imgproxy's address (or the CDN's in front of it). Required.
    * `:key` and `:salt` - imgproxy's, in hex (`IMGPROXY_KEY`,
      `IMGPROXY_SALT`). Without them, URLs are unsigned (`/insecure/`):
      for development only, as anyone could ask for any size.
    * `:source` - where imgproxy reads the original: a prefix the key is
      put after (`"s3://my-bucket/"`, `"local:///"`), or a function of the
      file that gives its address. The default is the store's URL of the
      file (`Storehouse.url/2`).
    * `:extension` - `true` ends the URL with the format's extension
      (`…/<source>.webp`) in place of `f:`. The default is `false`.

  ## Its own addresses

  For URLs of another shape (a CDN's Worker that signs them itself),
  `signed_path/2` gives the path imgproxy is asked, and a renderer of the
  app's own builds the rest.
  """

  @behaviour Storehouse.Renderer

  @gravity %{centre: "g:ce", attention: "g:sm", entropy: "g:sm"}

  @impl true
  def url(%Storehouse.Variant{} = variant, %Storehouse.File{} = file, opts) do
    base = opts |> Keyword.fetch!(:url) |> String.trim_trailing("/")
    base <> signed_path(path(variant, file, opts), opts)
  end

  @doc """
  The path of `variant` for imgproxy, not yet signed:
  `/<processing options>/<encoded source>`.
  """
  @spec path(Storehouse.Variant.t(), Storehouse.File.t(), keyword()) :: String.t()
  def path(%Storehouse.Variant{} = variant, %Storehouse.File{} = file, opts) do
    options = processing(variant, opts)
    source = Base.url_encode64(source(file, Keyword.get(opts, :source)), padding: false)
    extension = if opts[:extension], do: suffix(variant.format), else: ""
    "/" <> Enum.join(options ++ [source <> extension], "/")
  end

  @doc """
  `path` signed with the options' `:key` and `:salt`: `"/<signature><path>"`,
  as imgproxy checks it (HMAC-SHA256 of the salt and the path), or
  `"/insecure<path>"` without them.
  """
  @spec signed_path(String.t(), keyword()) :: String.t()
  def signed_path(path, opts) do
    case {Keyword.get(opts, :key), Keyword.get(opts, :salt)} do
      {nil, nil} ->
        "/insecure" <> path

      {key, salt} when is_binary(key) and is_binary(salt) ->
        signature =
          :hmac
          |> :crypto.mac(
            :sha256,
            Base.decode16!(key, case: :mixed),
            Base.decode16!(salt, case: :mixed) <> path
          )
          |> Base.url_encode64(padding: false)

        "/" <> signature <> path

      _ ->
        raise ArgumentError, "imgproxy's :key and :salt are given together, in hex"
    end
  end

  defp processing(variant, opts) do
    Enum.reject(
      [
        size(variant),
        variant.quality && "q:#{variant.quality}",
        format(variant, opts),
        variant.profile == :keep && "scp:0",
        variant.metadata == :all && "sm:0",
        variant.background && "bg:" <> String.trim_leading(variant.background, "#"),
        Keyword.get(variant.options, :imgproxy)
      ],
      &(&1 in [nil, false, ""])
    )
  end

  defp size(%{fit: :inside, height: nil, width: width}), do: "w:#{width}"
  defp size(%{fit: :inside} = variant), do: "rs:fit:#{variant.width}:#{variant.height}"

  defp size(%{fit: :cover} = variant),
    do: "rs:fill:#{variant.width}:#{variant.height}/" <> gravity(variant.focus)

  defp gravity({x, y}), do: "g:fp:#{decimal(x)}:#{decimal(y)}"
  defp gravity(focus), do: Map.fetch!(@gravity, focus)

  defp decimal(value), do: :erlang.float_to_binary(value / 1, [:short])

  # One format, unless it is the original's (imgproxy's own default) or
  # chosen by imgproxy from several.
  defp format(%{format: formats}, _opts) when is_list(formats), do: nil
  defp format(%{format: :original}, _opts), do: nil

  defp format(%{format: format}, opts) do
    if opts[:extension], do: nil, else: "f:#{extension(format)}"
  end

  # The extension for one format of its own; none for the original's, or
  # several.
  defp suffix(format) when is_list(format) or format == :original, do: ""
  defp suffix(format), do: "." <> extension(format)

  defp extension(:jpeg), do: "jpg"
  defp extension(format), do: Atom.to_string(format)

  defp source(file, nil), do: Storehouse.url(file.key)
  defp source(file, prefix) when is_binary(prefix), do: prefix <> file.key
  defp source(file, fun) when is_function(fun, 1), do: fun.(file)
end
