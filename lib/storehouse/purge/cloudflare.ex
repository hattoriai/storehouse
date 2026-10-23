defmodule Storehouse.Purge.Cloudflare do
  @moduledoc """
  A purger (`Storehouse.Purge`) for Cloudflare's cache: a zone's
  `purge_cache`, with an API token that may purge it.

      config :storehouse, Storehouse.Purge,
        purger:
          {Storehouse.Purge.Cloudflare,
           zone_id: System.fetch_env!("CLOUDFLARE_ZONE_ID"),
           api_token: System.fetch_env!("CLOUDFLARE_API_TOKEN"),
           by: [:urls, :tags]},
        base_url: "https://example.com"

  URLs go thirty a request, tags and prefixes a hundred and thirty, as
  Cloudflare takes them.

  ## Options

    * `:zone_id` and `:api_token` (required).
    * `:by` - what to purge by: `:urls` (every plan), `:tags` and
      `:prefixes` (where the plan purges by them). The default is
      `[:urls]`.
    * `:endpoint` - Cloudflare's API. The default is
      `"https://api.cloudflare.com/client/v4"`.
    * `:timeout` - for each request, in milliseconds. The default is
      15 seconds.
  """

  @behaviour Storehouse.Purge

  @batches %{urls: {:files, 30}, tags: {:tags, 100}, prefixes: {:prefixes, 30}}

  @impl true
  def purge(request, opts) do
    zone = Keyword.fetch!(opts, :zone_id)
    token = Keyword.fetch!(opts, :api_token)
    endpoint = Keyword.get(opts, :endpoint, "https://api.cloudflare.com/client/v4")
    url = String.trim_trailing(endpoint, "/") <> "/zones/#{zone}/purge_cache"

    bodies =
      for kind <- Keyword.get(opts, :by, [:urls]),
          {field, size} = Map.fetch!(@batches, kind),
          batch <- request |> Map.get(kind, []) |> Enum.uniq() |> Enum.chunk_every(size),
          do: %{field => batch}

    Enum.reduce_while(bodies, :ok, fn body, :ok ->
      case post(url, token, body, Keyword.get(opts, :timeout, 15_000)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp post(url, token, body, timeout) do
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

    request =
      {String.to_charlist(url), [{~c"authorization", String.to_charlist("Bearer " <> token)}],
       ~c"application/json", Storehouse.JSON.encode!(body)}

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:cloudflare, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
