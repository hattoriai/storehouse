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

  @typedoc """
  What a store knows of a file without reading it: its size in `:bytes`,
  its `:content_type` as stored (or `nil`), and its `:checksum`, the
  SHA-256 in Base64 (or `nil` when the store keeps none).
  """
  @type head :: %{
          bytes: non_neg_integer(),
          content_type: String.t() | nil,
          checksum: String.t() | nil
        }

  @doc """
  What the store knows of the file with `key`, without reading it: to
  learn its size before a byte of it is read (`Storehouse.head/2`). A
  missing file gives `{:error, :enoent}`. Optional, with
  `c:read_range/3`.
  """
  @callback head(key()) :: {:ok, head()} | {:error, term()}

  @doc """
  The bytes of the file with `key` from `first` to `last`, both included
  (fewer, when the file ends sooner; `""` past its end): what
  `Storehouse.read/2`, `Storehouse.stream/2` and `Storehouse.download/3`
  read the file with, a part at a time. A missing file gives
  `{:error, :enoent}`. Optional, with `c:head/1`.
  """
  @callback read_range(key(), first :: non_neg_integer(), last :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @typedoc "A file `c:list/1` gives: its key, its size, and when it was last written."
  @type entry :: %{key: key(), bytes: non_neg_integer(), modified_at: DateTime.t()}

  @doc """
  The files whose keys start with `prefix`, in the order of their keys, as
  an enumerable that asks the store as it is taken (and raises
  `Storehouse.ReadError` when the store fails then). Optional. See
  `Storehouse.list/2`.
  """
  @callback list(prefix :: String.t()) :: {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Deletes the files with `keys`, at most a thousand, at once. A key with no
  file is deleted. Optional: without it, `Storehouse.delete_prefix/2`
  deletes one at a time with `c:delete/1`.
  """
  @callback delete_many([key()]) :: :ok | {:error, term()}

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

  @doc """
  Told that a file the browser uploaded straight to the store
  (`c:presign_upload/3`) was checked and kept (`Storehouse.verify_upload/2`):
  for a store that does more with a file it takes (`Storehouse.Mirror`
  copies it to its mirrors). Optional.
  """
  @callback uploaded(key()) :: :ok

  @optional_callbacks uploaded: 1,
                      presign_upload: 3,
                      signed_url: 2,
                      read_head: 2,
                      head: 1,
                      read_range: 3,
                      list: 1,
                      delete_many: 1,
                      checksum: 1,
                      copy: 2,
                      stream_open: 2,
                      stream_write: 2,
                      stream_close: 1,
                      stream_abort: 1
end
