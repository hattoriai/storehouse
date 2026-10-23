defmodule Storehouse.Analysis do
  @moduledoc """
  What an analysis step (`Storehouse.Analyzer`) made of a file, kept in the
  file's `:analysis`, by the step's name:

    * `:status` - `:ok`, `:skipped` (the step does not apply to the file)
      or `:failed`.
    * `:result` - what the step read, a map JSON holds
      (`Storehouse.Metadata`), as the step gave it: `%{}` unless `:ok`.
    * `:error` - why it failed, or `nil`.
    * `:at` - when it ran, a `DateTime`.

  The step's result is never mixed with Storehouse's own keys: a step may
  give `%{"error" => …}` of its own, and it is a result like any other.
  """

  @enforce_keys [:status, :at]
  defstruct [:status, :error, :at, result: %{}]

  @type status :: :ok | :skipped | :failed
  @type t :: %__MODULE__{
          status: status(),
          result: map(),
          error: String.t() | nil,
          at: DateTime.t()
        }

  @statuses %{"ok" => :ok, "skipped" => :skipped, "failed" => :failed}

  @doc false
  @spec ok(map()) :: t()
  def ok(result), do: %__MODULE__{status: :ok, result: result, at: now()}

  @doc false
  @spec skipped() :: t()
  def skipped, do: %__MODULE__{status: :skipped, at: now()}

  @doc false
  @spec failed(term()) :: t()
  def failed(reason) do
    message = if is_binary(reason), do: reason, else: inspect(reason)
    %__MODULE__{status: :failed, error: String.slice(message, 0, 500), at: now()}
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  The analysis as a map with string keys, for JSON and a record's column.

  ## Examples

      iex> analysis = %Storehouse.Analysis{status: :ok, result: %{"pages" => 12}, at: ~U[2026-10-23 08:00:00Z]}
      iex> Storehouse.Analysis.to_map(analysis)
      %{"status" => "ok", "result" => %{"pages" => 12}, "error" => nil, "at" => "2026-10-23T08:00:00Z"}

  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = analysis) do
    %{
      "status" => Atom.to_string(analysis.status),
      "result" => analysis.result,
      "error" => analysis.error,
      "at" => DateTime.to_iso8601(analysis.at)
    }
  end

  @doc """
  The analysis of a map `to_map/1` gave, or `nil` for one it did not.
  """
  @spec from_map(term()) :: t() | nil
  def from_map(%{"status" => status, "at" => at} = map) when is_map_key(@statuses, status) do
    with true <- is_binary(at),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      %__MODULE__{
        status: Map.fetch!(@statuses, status),
        result: if(is_map(map["result"]), do: map["result"], else: %{}),
        error: if(is_binary(map["error"]), do: map["error"]),
        at: at
      }
    else
      _invalid -> nil
    end
  end

  def from_map(_other), do: nil

  if Code.ensure_loaded?(JSON.Encoder) do
    defimpl JSON.Encoder do
      def encode(analysis, encoder),
        do: JSON.Encoder.encode(Storehouse.Analysis.to_map(analysis), encoder)
    end
  end

  if Code.ensure_loaded?(Jason.Encoder) do
    defimpl Jason.Encoder do
      def encode(analysis, opts), do: Jason.Encode.map(Storehouse.Analysis.to_map(analysis), opts)
    end
  end
end
