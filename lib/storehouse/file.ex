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
    * `:metadata` - the app's own (`Storehouse.Metadata`): a caption, a
      credit. `%{}` when there is none.
    * `:analysis` - what the analysis steps made of the file
      (`Storehouse.Analyzer`), by step name, each a `Storehouse.Analysis`.
      `%{}` when none ran.

  ## In JSON

  A file encodes as JSON (`JSON.Encoder`, and `Jason.Encoder` when Jason is
  there) with its fields and metadata, but not its analysis: what a file's
  EXIF says can hold where a photo was taken. `to_map/2` chooses what goes.
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
    metadata: %{},
    analysis: %{}
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
          metadata: map(),
          analysis: %{String.t() => Storehouse.Analysis.t()}
        }

  @public ~w(key url name content_type bytes width height checksum preview metadata)a

  @doc "Whether the file is an image (PNG, JPEG, GIF or WebP)."
  @spec image?(t()) :: boolean()
  def image?(%__MODULE__{content_type: type}), do: type in Storehouse.Check.images()

  @doc """
  Merges `metadata` into the file's own (`Storehouse.Metadata.merge/2`):
  a caption a person entered, a credit. It is normalized first
  (`Storehouse.Metadata.normalize/1`), and refused with
  `{:error, {:invalid_metadata, path}}` when it holds what JSON does not.

  ## Examples

      iex> file = %Storehouse.File{key: "a.png", url: "/a.png", name: "a.png", content_type: "image/png", bytes: 1}
      iex> {:ok, file} = Storehouse.File.put_metadata(file, %{caption: "The quay"})
      iex> {:ok, file} = Storehouse.File.put_metadata(file, %{credit: "Ana"})
      iex> file.metadata
      %{"caption" => "The quay", "credit" => "Ana"}

  """
  @spec put_metadata(t(), map()) :: {:ok, t()} | {:error, {:invalid_metadata, list()}}
  def put_metadata(%__MODULE__{} = file, metadata) do
    with {:ok, metadata} <- Storehouse.Metadata.normalize(metadata) do
      {:ok, %{file | metadata: Storehouse.Metadata.merge(file.metadata || %{}, metadata)}}
    end
  end

  @doc """
  What the analysis step `step` made of the file (`Storehouse.Analysis`),
  or `nil` when it has not run.
  """
  @spec analysis(t(), String.t() | atom()) :: Storehouse.Analysis.t() | nil
  def analysis(%__MODULE__{analysis: analysis}, step),
    do: Map.get(analysis || %{}, to_string(step))

  @doc """
  What the analysis step `step` read from the file, when it ran and did
  not fail or skip it: its result, else `nil`.

  ## Examples

      iex> file = %Storehouse.File{key: "a.pdf", url: "/a.pdf", name: "a.pdf", content_type: "application/pdf", bytes: 1}
      iex> file = Storehouse.File.put_analysis(file, "pages", Storehouse.Analysis.ok(%{"pages" => 12}))
      iex> Storehouse.File.analyzed(file, :pages)
      %{"pages" => 12}

  """
  @spec analyzed(t(), String.t() | atom()) :: map() | nil
  def analyzed(%__MODULE__{} = file, step) do
    case analysis(file, step) do
      %Storehouse.Analysis{status: :ok, result: result} -> result
      _not_ok -> nil
    end
  end

  @doc false
  # The analysis of a step, in place of what it made of the file before.
  @spec put_analysis(t(), String.t(), Storehouse.Analysis.t()) :: t()
  def put_analysis(%__MODULE__{} = file, step, %Storehouse.Analysis{} = analysis),
    do: %{file | analysis: Map.put(file.analysis || %{}, to_string(step), analysis)}

  @doc """
  The file as a map with string keys, for JSON: its fields and metadata,
  without its analysis unless asked.

    * `:only` - the fields to give, of `#{inspect(@public)}`. The default
      is all of them.
    * `:analysis` - the analysis steps to give, under `"analysis"`: a list
      of their names, or `true` for every one. The default is none.

  ## Examples

      iex> file = %Storehouse.File{key: "a.png", url: "/a.png", name: "a.png", content_type: "image/png", bytes: 1, metadata: %{"caption" => "Hi"}}
      iex> Storehouse.File.to_map(file, only: [:url, :metadata])
      %{"url" => "/a.png", "metadata" => %{"caption" => "Hi"}}

  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = file, opts \\ []) do
    fields = Keyword.get(opts, :only, @public)

    file
    |> Map.from_struct()
    |> Map.take(Enum.filter(fields, &(&1 in @public)))
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> put_analysis_map(file.analysis || %{}, Keyword.get(opts, :analysis, []))
  end

  defp put_analysis_map(map, _analysis, []), do: map

  defp put_analysis_map(map, analysis, steps) do
    chosen =
      if steps == true, do: analysis, else: Map.take(analysis, Enum.map(steps, &to_string/1))

    Map.put(
      map,
      "analysis",
      Map.new(chosen, fn {step, a} -> {step, Storehouse.Analysis.to_map(a)} end)
    )
  end

  defimpl JSON.Encoder do
    def encode(file, encoder), do: JSON.Encoder.encode(Storehouse.File.to_map(file), encoder)
  end

  if Code.ensure_loaded?(Jason.Encoder) do
    defimpl Jason.Encoder do
      def encode(file, opts), do: Jason.Encode.map(Storehouse.File.to_map(file), opts)
    end
  end
end
