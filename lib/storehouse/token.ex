defmodule Storehouse.Token do
  @moduledoc false
  # What the app gives a browser with an upload it signed, and takes back
  # with the requests about it: the upload's key, its owner and the rest,
  # signed with the app's secret. A request then names only an upload the
  # app started, for that owner: never a file already stored, or another's.

  # A day to register an upload (a large file takes a while to send), a
  # week to finish one sent in parts (the browser reloaded, the person back
  # the next day).
  @max_ages %{"upload" => 86_400, "multipart" => 7 * 86_400}

  @spec sign(binary(), String.t(), map()) :: String.t()
  def sign(secret, kind, data) when is_binary(secret),
    do: Plug.Crypto.sign(secret, salt(kind), data)

  @spec verify(binary(), String.t(), term(), pos_integer() | nil) :: {:ok, map()} | :error
  def verify(secret, kind, token, max_age \\ nil)

  def verify(secret, kind, token, max_age) when is_binary(secret) and is_binary(token) do
    case Plug.Crypto.verify(secret, salt(kind), token, max_age: max_age || @max_ages[kind]) do
      {:ok, %{} = data} -> {:ok, data}
      _invalid -> :error
    end
  end

  def verify(_secret, _kind, _token, _max_age), do: :error

  defp salt(kind), do: "storehouse " <> kind
end
