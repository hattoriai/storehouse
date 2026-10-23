defmodule Storehouse.Analyzer.Size do
  @moduledoc """
  A step (`Storehouse.Analyzer`) that asks the store the file's size and
  type as stored, without reading it: `%{"bytes" => …, "content_type" => …}`,
  under `"size"`. For a file uploaded straight to the store, whose size
  was what the browser said until then.

      Storehouse.analyze(file, [Storehouse.Analyzer.Size])
  """

  @behaviour Storehouse.Analyzer

  @impl true
  def name, do: "size"

  @impl true
  def needs_file?, do: false

  @impl true
  def analyze(%Storehouse.File{key: key}, _path, opts) do
    with {:ok, head} <- Storehouse.head(key, Keyword.take(opts, [:adapter])) do
      {:ok, %{"bytes" => head.bytes, "content_type" => head.content_type}}
    end
  end
end
