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
  display only), `:content_type` (checked on the server, `Storehouse.Check`),
  `:bytes`, and `:checksum` (its SHA-256, in Base64), which a store that
  can checks as it takes the file (`Storehouse.S3` does).
  """
  @type meta :: %{
          optional(:name) => String.t(),
          optional(:content_type) => String.t(),
          optional(:bytes) => non_neg_integer(),
          optional(:checksum) => String.t()
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

  @typedoc """
  An upload a browser makes, straight to the store: an HTTP `method`, a
  `url` that carries its signature, and the `headers` it sends as they
  are.
  """
  @type upload :: %{method: String.t(), url: String.t(), headers: %{String.t() => String.t()}}

  @doc """
  An upload of the file with `key` that a browser makes itself, without
  the store's keys, valid `opts[:expires_in]` seconds: of `meta.bytes`
  bytes exactly, of the type `meta.content_type`. Optional: a store
  without it takes its files through the app (`Storehouse.store/2`).
  See `Storehouse.presign_upload/4`.
  """
  @callback presign_upload(key(), meta(), opts :: keyword()) :: {:ok, upload()} | {:error, term()}

  @doc """
  A URL of the file with `key` that is valid `opts[:expires_in]` seconds,
  for a file that is not public. `opts[:disposition]` is `"inline"` or
  `"attachment"`, and `opts[:filename]` the name a download gets, when
  given. Optional. See `Storehouse.signed_url/2`.
  """
  @callback signed_url(key(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  The first `bytes` bytes of the file with `key` (all of it, when it is
  shorter), and its size: to check a file uploaded straight to the store.
  Optional; needed with `c:presign_upload/3`.
  """
  @callback read_head(key(), bytes :: pos_integer()) ::
              {:ok, head :: binary(), size :: non_neg_integer()} | {:error, term()}

  @doc """
  The SHA-256 of the file with `key`, in Base64, as the store knows it, or
  `nil` when it keeps none: for a file uploaded straight to it. Optional.
  """
  @callback checksum(key()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Copies the file with key `from` to the key `to`, in the store, without
  it going through the app: to make a temporary file permanent
  (`Storehouse.promote/2`). A missing `from` gives `{:error, :enoent}`.
  Optional.
  """
  @callback copy(from :: key(), to :: key()) :: :ok | {:error, term()}

  @doc """
  Opens a file with `key` that its bytes are written to as they come, in
  `c:stream_write/2`: an upload streamed through the app, with no file of
  its own on the disk (`Storehouse.Live.allow/3`, `mode: :stream`).
  Optional, with the three other `stream_` callbacks.
  """
  @callback stream_open(key(), meta()) :: {:ok, stream :: term()} | {:error, term()}

  @doc "Writes the next bytes of a streamed file."
  @callback stream_write(stream :: term(), iodata()) :: {:ok, stream :: term()} | {:error, term()}

  @doc "Ends a streamed file, which is then in the store: its URL."
  @callback stream_close(stream :: term()) :: {:ok, url :: String.t()} | {:error, term()}

  @doc "Gives up a streamed file: nothing of it stays in the store."
  @callback stream_abort(stream :: term()) :: :ok

  @optional_callbacks presign_upload: 3,
                      signed_url: 2,
                      read_head: 2,
                      checksum: 1,
                      copy: 2,
                      stream_open: 2,
                      stream_write: 2,
                      stream_close: 1,
                      stream_abort: 1
end
