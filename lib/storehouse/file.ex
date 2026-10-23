defmodule Storehouse.File do
  @moduledoc """
  A stored file: what `Storehouse.store/2` gives, and what an app keeps in
  its records (or a document's data) to show and serve it again.

    * `:key` - its key in the store (`Storehouse.key/2`).
    * `:url` - its URL, from the store.
    * `:name` - the client's file name, for display only
      (`Storehouse.clean_name/1`).
    * `:content_type` - the type its bytes prove (`Storehouse.Check`).
    * `:bytes` - its size.
    * `:width` and `:height` - an image's, as a browser draws it (turned as
      a JPEG's EXIF says), or `nil`.
    * `:preview` - the URL of a smaller image of it (a thumbnail, a PDF's
      first page, a video's poster), when the app made one, or `nil`.
  """

  @enforce_keys [:key, :url, :name, :content_type, :bytes]
  defstruct [:key, :url, :name, :content_type, :bytes, :width, :height, :preview]

  @type t :: %__MODULE__{
          key: Storehouse.Adapter.key(),
          url: String.t(),
          name: String.t(),
          content_type: String.t(),
          bytes: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          preview: String.t() | nil
        }

  @doc "Whether the file is an image (PNG, JPEG, GIF or WebP)."
  @spec image?(t()) :: boolean()
  def image?(%__MODULE__{content_type: type}), do: type in Storehouse.Check.images()
end
