defmodule Storehouse.Archive.Entry do
  @moduledoc """
  A file of an archive, as a format (`Storehouse.Archive.Format`) is given
  it:

    * `:name` - its path in the archive, checked safe.
    * `:size` - its size in bytes, or `nil` when it is not known before it
      is read (a stream, a function's).
    * `:content_type` - the store's, else its name's.
    * `:compress` - whether to compress it (`Storehouse.Archive`'s
      `:compression`).
    * `:data` - a function of nothing that gives its bytes, an enumerable
      of iodata, read as it is taken.
  """

  @enforce_keys [:name, :size, :content_type, :compress, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          size: non_neg_integer() | nil,
          content_type: String.t(),
          compress: boolean(),
          data: (-> Enumerable.t())
        }
end

defmodule Storehouse.Archive.Format do
  @moduledoc """
  A format of archive (`Storehouse.Archive`): zip (`Storehouse.Archive.Zip`,
  the default), tar (`Storehouse.Archive.Tar`), or one of the app's.

      config :storehouse, archive_format: MyApp.SevenZip

  `Storehouse.Archive` reads the files, checks their names, decides which
  to compress, splits and stores the archive: a format only lays out
  bytes. It is given each file as a `Storehouse.Archive.Entry`, and the
  options of the call (`:compression`, `:password`, `:modified_at`, its
  own).
  """

  alias Storehouse.Archive.Entry

  @doc "The archive, as a stream of iodata, made as it is taken."
  @callback stream([Entry.t()], opts :: keyword()) :: Enumerable.t()

  @doc """
  Its size before it is made: `{:ok, bytes}` exact, `{:about, bytes}`
  near enough (compressed), or `:unknown` (a file's size is not known).
  """
  @callback size([Entry.t()], opts :: keyword()) ::
              {:ok, non_neg_integer()} | {:about, non_neg_integer()} | :unknown

  @doc """
  The most bytes a file of known size takes in the archive, its headers
  with it: how `:max_bytes` splits.
  """
  @callback bound(Entry.t(), opts :: keyword()) :: non_neg_integer()

  @doc "The most bytes the end of an archive of `count` files takes."
  @callback end_bound(count :: non_neg_integer(), opts :: keyword()) :: non_neg_integer()

  @doc "The archive's content type."
  @callback content_type([Entry.t()], opts :: keyword()) :: String.t()
end
