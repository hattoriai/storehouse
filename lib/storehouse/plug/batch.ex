defmodule Storehouse.Plug.Batch do
  @moduledoc false
  # What Storehouse.Plug.Presign and Storehouse.Plug.Register share: the
  # options that are functions of the conn, the JSON in, and the JSON out.

  import Plug.Conn

  @functions [:owner, :room, :existing]

  def init(opts, own) do
    {mine, batch} = Keyword.split(opts, own ++ @functions)
    Keyword.put(mine, :batch, batch)
  end

  # The batch's options for this request: the owner, the room and the
  # files the app has, asked of the app's functions with the conn.
  def batch_opts(conn, opts) do
    owner = call(opts[:owner], [conn])
    room = call(opts[:room], [conn])

    existing =
      case opts[:existing] do
        nil -> nil
        fun -> fn checksum -> fun.(conn, checksum) end
      end

    opts[:batch]
    |> put_present(:owner, owner)
    |> put_present(:room, room)
    |> put_present(:existing, existing)
  end

  defp call(nil, _args), do: nil
  defp call(fun, args) when is_function(fun), do: apply(fun, args)
  defp call(value, _args), do: value

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # The request's "uploads": parsed by Plug.Parsers, or read here.
  def items(conn) do
    case conn.body_params do
      %{"uploads" => items} when is_list(items) ->
        {:ok, conn, items}

      %Plug.Conn.Unfetched{} ->
        with {:ok, body, conn} <- read_body(conn, length: 1_000_000),
             {:ok, %{"uploads" => items}} when is_list(items) <- Storehouse.JSON.decode(body) do
          {:ok, conn, items}
        else
          _invalid -> {:error, conn}
        end

      _other ->
        {:error, conn}
    end
  end

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Storehouse.JSON.encode!(data))
    |> halt()
  end

  def error(conn, status, code), do: json(conn, status, %{"error" => Atom.to_string(code)})

  # A result of the batch, as JSON.
  def result({:ok, %Storehouse.File{} = file}), do: %{"file" => Storehouse.File.to_map(file)}

  def result({:ok, upload}),
    do: %{
      "upload" => %{
        "key" => upload.key,
        "method" => upload.method,
        "url" => upload.url,
        "headers" => upload.headers
      }
    }

  def result({:existing, file}), do: %{"existing" => Storehouse.File.to_map(file)}
  def result({:error, code}) when is_atom(code), do: %{"error" => Atom.to_string(code)}
  def result({:error, _reason}), do: %{"error" => "upload_failed"}
end
