defmodule Storehouse.Adapter do
  @moduledoc """
  A store of files: the local disk (`Storehouse.Local`), S3, another object
  store, a database. Name it in the config:

      config :storehouse, adapter: MyApp.Storage

  or give it per call with the `:adapter` option of `Storehouse.store/2`.

  It has three callbacks, Kotoba's and Hakushi's (`Kotoba.Storage`,
  `Hakushi.Storage`): a store written for one of them is a Storehouse
  adapter as it is.

  ## An S3 adapter

  With `ExAws.S3`:

      defmodule MyApp.Storage do
        @behaviour Storehouse.Adapter

        @bucket "my-app-uploads"

        @impl true
        def put(key, path, meta) do
          disposition = if Storehouse.Check.inline?(meta.content_type), do: "inline", else: "attachment"

          path
          |> ExAws.S3.Upload.stream_file()
          |> ExAws.S3.upload(@bucket, key, content_type: meta.content_type, content_disposition: disposition)
          |> ExAws.request()
          |> case do
            {:ok, _response} -> {:ok, url(key)}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def url(key), do: "https://\#{@bucket}.s3.amazonaws.com/" <> key

        @impl true
        def delete(key) do
          case ExAws.request(ExAws.S3.delete_object(@bucket, key)) do
            {:ok, _response} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end

  The URL goes into the app's records and documents, so it must stay
  valid: a public or CDN URL, or a path of the app (`"/files/" <> key`)
  whose controller checks access and redirects to a short-lived signed
  URL. See the [Stores](stores.md) guide.
  """

  @typedoc "A storage key, for example `\"2026/10/0b6…-board.png\"` (`Storehouse.key/2`)."
  @type key :: String.t()

  @typedoc """
  What Storehouse knows of the file: `:name` (the client's name, for
  display only), `:content_type` (checked on the server, `Storehouse.Check`)
  and `:bytes`.
  """
  @type meta :: %{
          optional(:name) => String.t(),
          optional(:content_type) => String.t(),
          optional(:bytes) => non_neg_integer()
        }

  @doc """
  Stores the file at `path` under `key`, and returns its URL.

  The file at `path` is a temporary file: the adapter copies it, and keeps
  no reference to it.
  """
  @callback put(key(), path :: Path.t(), meta()) :: {:ok, url :: String.t()} | {:error, term()}

  @doc "Returns the URL of the file with `key`."
  @callback url(key()) :: String.t()

  @doc "Deletes the file with `key`. A key with no file gives `:ok`."
  @callback delete(key()) :: :ok | {:error, term()}
end
