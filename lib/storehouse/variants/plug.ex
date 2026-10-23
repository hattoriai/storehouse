defmodule Storehouse.Variants.Plug do
  @moduledoc """
  Serves variants (`Storehouse.Variants`) at the URLs
  `Storehouse.variant_url/3` gives, making each the first time it is
  asked for: `GET <at>/<original key>/<preset>-<width>-<fingerprint>`.

  In the endpoint, before the router:

      plug Storehouse.Variants.Plug

  or in a router, where `forward` strips the path:

      forward "/variants", Storehouse.Variants.Plug, at: "/"

  Only a preset's widths are made: any other size, preset or key gives
  `404`, as does an original that is not there, or not an image. A
  fingerprint of a preset since changed is redirected (`302`) to the
  preset's current URL. The format of a preset of several is chosen by
  the request's `Accept`, with `Vary: Accept`.

  A variant is sent with `Cache-Control: public, max-age=31536000,
  immutable`: its URL changes when its preset does, so a CDN in front
  keeps it for a year.

  ## Options

    * `:at` - the request path. The default is the configured `:url`
      (`"/variants"`).
    * `:only` - which originals have variants: a list of key prefixes,
      or a function of the key. The default is every key with a preset's
      name, width and fingerprint: originals that must stay private
      (served only at signed URLs) are left out with it.
    * `:cache_tag` - `true` sends the original's `Cache-Tag`
      (`Storehouse.Purge.cache_tag/1`) with each of its variants, for a
      purge by tag.
    * `:adapter` - the store. The default is `Storehouse.adapter/0`.
    * The configuration's (`:presets`, `:renderer`, `:prefix`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Storehouse.Variants

  @variant ~r/\A([a-z0-9_]+)-(\d{1,5})-([0-9a-f]{8})\z/
  @year "public, max-age=31536000, immutable"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    config = Variants.config(Keyword.take(opts, [:presets, :renderer, :prefix, :url, :timeout]))
    at = opts |> Keyword.get(:at, config.url) |> Path.split() |> Enum.reject(&(&1 == "/"))

    case Enum.split(conn.path_info, length(at)) do
      {^at, [_ | _] = rest} -> conn |> serve(rest, config, opts) |> halt()
      _other -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp serve(conn, segments, config, opts) do
    {key_segments, [last]} = Enum.split(segments, -1)
    key = Enum.join(key_segments, "/")

    with [_, name, width, fingerprint] <- Regex.run(@variant, last),
         true <- Storehouse.valid_key?(key),
         false <- String.starts_with?(key, config.prefix),
         true <- only?(key, Keyword.get(opts, :only)),
         {:ok, preset, width} <- Variants.preset_for(config, name, width),
         "image/" <> _ <- Variants.file(key).content_type do
      variant(conn, key, preset, width, fingerprint, config, opts)
    else
      _not_one -> send_resp(conn, 404, "")
    end
  end

  defp variant(conn, key, preset, width, fingerprint, config, opts) do
    current = Variants.variant_for(key, preset, width, [], :url)

    if current.fingerprint == fingerprint do
      accept = conn |> get_req_header("accept") |> Enum.join(",")
      adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
      call_opts = Keyword.take(opts, [:presets, :renderer, :prefix, :timeout])

      # Tagged with the original's key: a purge of it forgets its variants.
      conn = Storehouse.Purge.put_cache_tag(conn, opts[:cache_tag], key)

      key
      |> Variants.get(preset.name, call_opts ++ [width: width, accept: accept, adapter: adapter])
      |> sent(conn, preset, adapter)
    else
      conn
      |> put_resp_header("location", Variants.plug_url(current, config))
      |> put_resp_header("cache-control", "public, max-age=300")
      |> send_resp(302, "")
    end
  end

  defp sent({:ok, file}, conn, preset, adapter) do
    case Storehouse.read(file.key, adapter: adapter) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(file.content_type, nil)
        |> put_resp_header("cache-control", @year)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> vary(preset)
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: body))

      error ->
        sent(error, conn, preset, adapter)
    end
  end

  defp sent({:error, :enoent}, conn, _preset, _adapter), do: send_resp(conn, 404, "")
  defp sent({:error, :timeout}, conn, _preset, _adapter), do: send_resp(conn, 503, "")

  defp sent({:error, reason}, conn, _preset, _adapter) do
    Logger.warning(
      "Storehouse: a variant of #{conn.request_path} was not made: #{inspect(reason)}"
    )

    send_resp(conn, 500, "")
  end

  defp vary(conn, %{formats: [_, _ | _]}), do: put_resp_header(conn, "vary", "Accept")
  defp vary(conn, _preset), do: conn

  defp only?(_key, nil), do: true

  defp only?(key, prefixes) when is_list(prefixes),
    do: Enum.any?(prefixes, &String.starts_with?(key, &1))

  defp only?(key, fun) when is_function(fun, 1), do: fun.(key) == true
end
