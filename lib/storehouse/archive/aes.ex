defmodule Storehouse.Archive.AES do
  @moduledoc false
  # WinZip's AES encryption of a zip's file (AE-2), AES-256: a key of the
  # password and a salt of the file's own (PBKDF2, HMAC-SHA1, 1,000
  # rounds), the bytes in CTR mode with WinZip's counter (little-endian,
  # from 1), and an HMAC-SHA1 of them, of which its first ten bytes end
  # the file.

  @doc false
  # The file's first bytes (salt, password verifier), and the cipher.
  def open(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(16)

    <<key::binary-32, mac_key::binary-32, verifier::binary-2>> =
      :crypto.pbkdf2_hmac(:sha, password, salt, 1_000, 66)

    {salt <> verifier,
     %{key: key, counter: 1, pending: "", mac: :crypto.mac_init(:hmac, :sha, mac_key)}}
  end

  def open(_password), do: raise(ArgumentError, "a zip's password is a string")

  @doc false
  def encrypt(state, data) do
    data = IO.iodata_to_binary(data)
    size = byte_size(data)
    blocks = max(div(size - byte_size(state.pending) + 15, 16), 0)

    stream =
      if blocks > 0 do
        counters =
          for i <- state.counter..(state.counter + blocks - 1)//1,
              into: <<>>,
              do: <<i::little-128>>

        state.pending <> :crypto.crypto_one_time(:aes_256_ecb, state.key, counters, true)
      else
        state.pending
      end

    <<used::binary-size(^size), pending::binary>> = stream
    out = :crypto.exor(data, used)
    :crypto.mac_update(state.mac, out)
    {out, %{state | counter: state.counter + blocks, pending: pending}}
  end

  @doc false
  # The HMAC's first ten bytes: the file's last.
  def mac(state), do: binary_part(:crypto.mac_final(state.mac), 0, 10)
end
