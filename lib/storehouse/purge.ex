defmodule Storehouse.Purge do
  @moduledoc """
  What a CDN in front forgets when a file is deleted: the file's URLs, its
  variants' (`Storehouse.Variants`), and its cache tag. Keys are never
  reused, so a file kept for a year never changes; it only goes, and a
  CDN would go on serving it. A purger tells the CDN.

      config :storehouse, Storehouse.Purge,
        purger:
          {Storehouse.Purge.Cloudflare,
           zone_id: System.fetch_env!("CLOUDFLARE_ZONE_ID"),
           api_token: System.fetch_env!("CLOUDFLARE_API_TOKEN")},
        base_url: "https://example.com"

  After `Storehouse.delete/2` of a file (a file replaced is the old one
  deleted), the purger is given its URLs, its variants' URLs and its
  cache tag, once. After `Storehouse.delete_prefix/2` (an account's files),
  the prefix's URLs, for a CDN that purges by prefix. It runs as a job of
  the app's runner (`Storehouse.Runner`), tried again when the CDN fails,
  and its job holds the URLs, never the purger's credentials, which are
  read from the config when it runs.

  ## Configuration

    * `:purger` - a module of this behaviour, or `{module, options}`.
      Without it, nothing is purged.
    * `:base_url` - put before a URL that is a path (`Storehouse.Local`'s,
      `Storehouse.Variants.Plug`'s): the CDN's host.
    * `:urls` - a function of a key that gives more URLs of it: the app's
      own routes to it, through `Storehouse.Proxy` or `Storehouse.Redirect`.

  ## Cache tags

  `Storehouse.Proxy`, `Storehouse.Variants.Plug` and `Storehouse.Local.Plug`
  send a file's `Cache-Tag` (`cache_tag/1`) with `cache_tag: true`, its
  variants' with the original's: a purge by tag forgets them all, however
  many URLs they were served at.
  """

  require Logger

  alias Storehouse.Jobs

  @typedoc "What to forget: URLs, cache tags, and URL prefixes."
  @type request :: %{urls: [String.t()], tags: [String.t()], prefixes: [String.t()]}

  @doc "Tells the CDN to forget what `request` names."
  @callback purge(request(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  The cache tag of the file with `key`, and of its variants: `sh-` and 20
  hex digits of its SHA-256, short, and the same however the key is
  written in a URL.

      iex> Storehouse.Purge.cache_tag("2026/10/0b6-harbour.jpg")
      "sh-cddbf11b0099a58fca2e"
  """
  @spec cache_tag(String.t()) :: String.t()
  def cache_tag(key) when is_binary(key),
    do:
      "sh-" <> (:sha256 |> :crypto.hash(key) |> binary_part(0, 10) |> Base.encode16(case: :lower))

  @doc false
  # The response's Cache-Tag, when the plug is asked to send it.
  def put_cache_tag(conn, true, key) when is_binary(key),
    do: Plug.Conn.put_resp_header(conn, "cache-tag", cache_tag(key))

  def put_cache_tag(conn, _send?, _key), do: conn

  @doc """
  What the purger is given when the file with `key` is deleted: its URL,
  its variants' URLs and the app's (`:urls`), absolute, and its cache tag.
  """
  @spec request(String.t(), keyword()) :: request()
  def request(key, opts \\ []) do
    config = config()
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)

    urls =
      [adapter.url(key)] ++
        Storehouse.Variants.all_urls(key, opts) ++ app_urls(config[:urls], key)

    %{
      urls: urls |> Enum.map(&absolute(&1, config[:base_url])) |> Enum.uniq(),
      tags: [cache_tag(key)],
      prefixes: []
    }
  end

  @doc false
  # After a file is deleted: its purge, as a job, when a purger is set.
  def deleted(key, opts) do
    if purger() && opts[:purge] != false, do: enqueue(request(key, opts), opts), else: :ok
  end

  @doc false
  # After the files under a prefix are deleted: the prefix's URLs.
  def deleted_prefix(prefix, opts) do
    if purger() && opts[:purge] != false do
      config = config()
      adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
      prefixes = [adapter.url(prefix) | Storehouse.Variants.url_prefixes(prefix, opts)]

      enqueue(
        %{
          urls: [],
          tags: [],
          prefixes: prefixes |> Enum.map(&absolute(&1, config[:base_url])) |> Enum.uniq()
        },
        opts
      )
    else
      :ok
    end
  end

  @doc false
  # The job's work: the configured purger, given the request.
  def run(request) do
    case purger() do
      {module, opts} -> module.purge(request, opts)
      nil -> :ok
    end
  end

  defp enqueue(request, opts) do
    job = Jobs.Purge.job(request)

    case Storehouse.Runner.enqueue(job, Keyword.take(opts, [:runner])) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Storehouse: a purge was not queued: #{inspect(reason)}")
        :ok
    end
  end

  defp config, do: Application.get_env(:storehouse, __MODULE__, [])

  defp purger do
    case config()[:purger] do
      nil -> nil
      {module, opts} when is_atom(module) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  defp app_urls(nil, _key), do: []
  defp app_urls(fun, key) when is_function(fun, 1), do: List.wrap(fun.(key))

  defp absolute("/" <> _ = path, base) when is_binary(base),
    do: String.trim_trailing(base, "/") <> path

  defp absolute(url, _base), do: url
end
