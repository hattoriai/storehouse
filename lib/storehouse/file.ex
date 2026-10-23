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
    * `:checksum` - the SHA-256 of its bytes, in Base64 (as S3's
      `x-amz-checksum-sha256`): the store checked it as it took the file,
      and `Storehouse.checksum/1` gives it of a copy, to compare. `nil` for
      a file uploaded straight to a store that keeps none
      (`Storehouse.verify_upload/2`).
    * `:preview` - the URL of a smaller image of it (a thumbnail, a PDF's
      first page, a video's poster), when the app made one, or `nil`.
    * `:metadata` - the app's own, and the analysis's under `"analyzed"`
      (`Storehouse.Metadata`): a caption, a credit, what was read from the
      file. `%{}` when there is none.

  ## In JSON

  A file encodes as JSON (`JSON.Encoder` on Elixir 1.18 and later, and
  `Jason.Encoder` when Jason is there) with its fields and the app's metadata, but not the analysis's:
  what a file's EXIF says can hold where a photo was taken.
  `to_map/2` chooses what goes.
  """

  @enforce_keys [:key, :url, :name, :content_type, :bytes]
  defstruct [
    :key,
    :url,
    :name,
    :content_type,
    :bytes,
    :width,
    :height,
    :checksum,
    :preview,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          key: Storehouse.Adapter.key(),
          url: String.t(),
          name: String.t(),
          content_type: String.t(),
          bytes: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          checksum: String.t() | nil,
          preview: String.t() | nil,
          metadata: map()
        }

  @analyzed "analyzed"
  @public ~w(key url name content_type bytes width height checksum preview metadata)a

  @doc "Whether the file is an image (PNG, JPEG, GIF or WebP)."
  @spec image?(t()) :: boolean()
  def image?(%__MODULE__{content_type: type}), do: type in Storehouse.Check.images()

  @doc """
  Merges `metadata` into the file's own (`Storehouse.Metadata.merge/2`):
  a caption a person entered, a credit. It is normalized first
  (`Storehouse.Metadata.normalize/1`), and refused with
  `{:error, {:invalid_metadata, path}}` when it holds what JSON does not;
  the key `"analyzed"`, the analysis's, is refused too.

  ## Examples

      iex> file = %Storehouse.File{key: "a.png", url: "/a.png", name: "a.png", content_type: "image/png", bytes: 1}
      iex> {:ok, file} = Storehouse.File.put_metadata(file, %{caption: "The quay"})
      iex> {:ok, file} = Storehouse.File.put_metadata(file, %{credit: "Ana"})
      iex> file.metadata
      %{"caption" => "The quay", "credit" => "Ana"}

  """
  @spec put_metadata(t(), map()) :: {:ok, t()} | {:error, {:invalid_metadata, list()}}
  def put_metadata(%__MODULE__{} = file, metadata) do
    with {:ok, metadata} <- Storehouse.Metadata.normalize(metadata),
         false <- Map.has_key?(metadata, @analyzed) && {:error, {:invalid_metadata, [@analyzed]}} do
      {:ok, %{file | metadata: Storehouse.Metadata.merge(file.metadata || %{}, metadata)}}
    end
  end

  @doc """
  Puts what the analysis step `step` read from the file, in place of what
  it read before, under the metadata's `"analyzed"`:
  `file.metadata["analyzed"][step]`. Refused as `put_metadata/2` refuses.

  ## Examples

      iex> file = %Storehouse.File{key: "a.png", url: "/a.png", name: "a.png", content_type: "image/png", bytes: 1}
      iex> {:ok, file} = Storehouse.File.put_analyzed(file, "placeholder", %{color: "#2a2722"})
      iex> file.metadata
      %{"analyzed" => %{"placeholder" => %{"color" => "#2a2722"}}}

  """
  @spec put_analyzed(t(), String.t() | atom(), map()) ::
          {:ok, t()} | {:error, {:invalid_metadata, list()}}
  def put_analyzed(%__MODULE__{} = file, step, result) when is_map(result) do
    with {:ok, %{@analyzed => analyzed}} <-
           Storehouse.Metadata.normalize(%{@analyzed => %{step => result}}) do
      metadata = file.metadata || %{}
      before = Map.get(metadata, @analyzed, %{})
      {:ok, %{file | metadata: Map.put(metadata, @analyzed, Map.merge(before, analyzed))}}
    end
  end

  @doc """
  What the analysis step `step` read from the file, or `nil`
  (`put_analyzed/3`).
  """
  @spec analyzed(t(), String.t() | atom()) :: map() | nil
  def analyzed(%__MODULE__{metadata: metadata}, step),
    do: get_in(metadata || %{}, [@analyzed, to_string(step)])

  @doc """
  The file as a map with string keys, for JSON: its fields, and its
  metadata without the analysis's.

    * `:only` - the fields to give, of `#{inspect(@public)}`. The default
      is all of them.
    * `:analyzed` - the analysis steps to give, under the metadata's
      `"analyzed"`: a list of their names, or `true` for every one. The
      default is none.

  ## Examples

      iex> file = %Storehouse.File{key: "a.png", url: "/a.png", name: "a.png", content_type: "image/png", bytes: 1, metadata: %{"caption" => "Hi", "analyzed" => %{"exif" => %{"gps" => [1, 2]}}}}
      iex> Storehouse.File.to_map(file, only: [:url, :metadata])
      %{"url" => "/a.png", "metadata" => %{"caption" => "Hi"}}

  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = file, opts \\ []) do
    fields = Keyword.get(opts, :only, @public)

    file
    |> Map.put(:metadata, public_metadata(file.metadata || %{}, Keyword.get(opts, :analyzed, [])))
    |> Map.take(Enum.filter(fields, &(&1 in @public)))
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
  end

  defp public_metadata(metadata, true), do: metadata

  defp public_metadata(metadata, steps) when is_list(steps) do
    case Map.take(Map.get(metadata, @analyzed, %{}), Enum.map(steps, &to_string/1)) do
      empty when empty == %{} -> Map.delete(metadata, @analyzed)
      analyzed -> Map.put(metadata, @analyzed, analyzed)
    end
  end

  if Code.ensure_loaded?(JSON.Encoder) do
    defimpl JSON.Encoder do
      def encode(file, encoder), do: JSON.Encoder.encode(Storehouse.File.to_map(file), encoder)
    end
  end

  if Code.ensure_loaded?(Jason.Encoder) do
    defimpl Jason.Encoder do
      def encode(file, opts), do: Jason.Encode.map(Storehouse.File.to_map(file), opts)
    end
  end
end
