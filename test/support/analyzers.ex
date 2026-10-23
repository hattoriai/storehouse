defmodule StorehouseTest.Analyzers do
  @moduledoc false
  # Analysis steps for the tests: each says to the test that it ran, with
  # what it was given.

  defmodule Bytes do
    @moduledoc false
    @behaviour Storehouse.Analyzer

    @impl true
    def analyze(file, path, opts) do
      notify({:bytes, file.key, path, path && File.exists?(path)}, opts)
      {:ok, %{"bytes" => File.stat!(path).size}}
    end

    defp notify(message, opts), do: if(pid = opts[:test], do: send(pid, message))
  end

  defmodule Head do
    @moduledoc false
    @behaviour Storehouse.Analyzer

    @impl true
    def name, do: "first_byte"

    @impl true
    def analyze(_file, path, opts) do
      if pid = opts[:test], do: send(pid, {:head, path})
      {:ok, %{"value" => path |> File.read!() |> binary_part(0, 1) |> :binary.first()}}
    end
  end

  defmodule NoFile do
    @moduledoc false
    @behaviour Storehouse.Analyzer

    @impl true
    def needs_file?, do: false

    @impl true
    def analyze(_file, path, opts) do
      if pid = opts[:test], do: send(pid, {:no_file, path})
      {:ok, %{"ran" => true}}
    end
  end

  defmodule Skip do
    @moduledoc false
    @behaviour Storehouse.Analyzer

    @impl true
    def needs_file?, do: false

    @impl true
    def analyze(_file, _path, _opts), do: :skip
  end

  defmodule Fail do
    @moduledoc false
    @behaviour Storehouse.Analyzer

    @impl true
    def needs_file?, do: false

    @impl true
    def analyze(_file, _path, opts) do
      if pid = opts[:test], do: send(pid, :fail_ran)

      case opts[:how] do
        :raise -> raise "the tool crashed"
        _error -> {:error, :no_tool}
      end
    end
  end

  @doc false
  def done(file, pid), do: send(pid, {:analyzed, file})
end
