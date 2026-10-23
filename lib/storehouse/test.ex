defmodule Storehouse.Test do
  @moduledoc """
  Assertions on the files a test stored, with `Storehouse.Memory`:

      import Storehouse.Test

      test "an avatar is stored, and the old one deleted", %{user: user} do
        {:ok, user} = Accounts.update_avatar(user, upload)

        assert_stored user.avatar.key
        refute_stored "avatars/old.png"
        assert [%{key: "avatars/" <> _}] = stored_files()
      end

  Each sees only the files of the calling test (see `Storehouse.Memory`'s
  checkout).
  """

  import ExUnit.Assertions

  alias Storehouse.Memory

  @doc """
  Asserts that a file is stored under `key`, or under a key that matches a
  regex. Gives the key.
  """
  @spec assert_stored(String.t() | Regex.t()) :: String.t()
  def assert_stored(%Regex{} = pattern) do
    keys = Memory.keys()

    Enum.find(keys, &Regex.match?(pattern, &1)) ||
      flunk(
        "No file stored under a key that matches #{inspect(pattern)}. Stored: #{inspect(keys)}"
      )
  end

  def assert_stored(key) when is_binary(key) do
    keys = Memory.keys()
    assert key in keys, "No file stored under #{inspect(key)}. Stored: #{inspect(keys)}"
    key
  end

  @doc "Asserts that no file is stored under `key`, or under a key that matches a regex."
  @spec refute_stored(String.t() | Regex.t()) :: :ok
  def refute_stored(%Regex{} = pattern) do
    matching = Enum.filter(Memory.keys(), &Regex.match?(pattern, &1))

    assert matching == [],
           "Files stored under keys that match #{inspect(pattern)}: #{inspect(matching)}"

    :ok
  end

  def refute_stored(key) when is_binary(key) do
    refute key in Memory.keys(), "A file is stored under #{inspect(key)}"
    :ok
  end

  @doc "The files stored, in the order of their keys: each with its `:key`, `:body`, `:content_type` and `:modified_at`."
  @spec stored_files() :: [map()]
  def stored_files, do: Enum.map(Memory.keys(), &Map.put(Memory.get(&1), :key, &1))
end
