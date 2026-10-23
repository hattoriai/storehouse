defmodule StorehouseTest.PrivateFiles do
  @moduledoc "A second local store, for the tests of named stores."
  use Storehouse.Local
end

defmodule StorehouseTest.Scratch do
  @moduledoc "A third local store, its config under another app."
  use Storehouse.Local, otp_app: :storehouse_test
end

defmodule StorehouseTest.Media do
  @moduledoc "A second S3 store: another bucket."
  use Storehouse.S3
end

defmodule StorehouseTest.Mirrored do
  @moduledoc "A mirror: PrivateFiles, and a copy of each file in Flaky."
  use Storehouse.Mirror, primary: StorehouseTest.PrivateFiles, mirrors: [StorehouseTest.Flaky]
end

defmodule StorehouseTest.Flaky do
  @moduledoc """
  A local store that fails while it is told to (`down/0`, `up/0`): a
  mirror that stops answering, then comes back.
  """
  @behaviour Storehouse.Adapter

  alias Storehouse.Local

  def down, do: :persistent_term.put(__MODULE__, :down)
  def up, do: :persistent_term.erase(__MODULE__)
  defp up?, do: :persistent_term.get(__MODULE__, :up) == :up

  def config, do: Application.get_env(:storehouse_test, __MODULE__, [])

  @impl true
  def put(key, path, meta),
    do: if(up?(), do: Local.put(config(), key, path, meta), else: {:error, :down})

  @impl true
  def url(key), do: Local.url(config(), key)
  @impl true
  def delete(key), do: if(up?(), do: Local.delete(config(), key), else: {:error, :down})
  @impl true
  def head(key), do: if(up?(), do: Local.head(config(), key), else: {:error, :down})
  @impl true
  def read_range(key, first, last), do: Local.read_range(config(), key, first, last)
  @impl true
  def list(prefix), do: Local.list(config(), prefix)
end
