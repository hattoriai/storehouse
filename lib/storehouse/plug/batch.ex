defmodule Storehouse.Plug.Batch do
  @moduledoc false
  # What Storehouse.Plug.Presign and Storehouse.Plug.Register share: the
  # options that are functions of the conn, the JSON in, and the JSON out.

  import Plug.Conn

  alias Plug.Conn.Utils

  @functions [:owner, :room, :existing]

  # Options already made (a server that calls init/1 again) are kept as
  # they are.
  def init(opts, own) do
    if Keyword.has_key?(opts, :batch), do: opts, else: split(opts, own)
  end

  defp split(opts, own) do
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
    |> Keyword.put_new_lazy(:secret, fn -> conn.secret_key_base end)
    |> put_present(:owner, owner)
    |> put_present(:room, room)
    |> put_present(:existing, existing)
  end

  # The secret tokens are signed with: the endpoint's, or the option's.
  def secret!(opts) do
    case opts[:secret] do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        secret

      _other ->
        raise ArgumentError,
              "Storehouse's upload plugs need a secret of at least 32 bytes: " <>
                "the endpoint's secret_key_base, or :secret"
    end
  end

  defp call(nil, _args), do: nil
  defp call(fun, args) when is_function(fun), do: apply(fun, args)
  defp call(value, _args), do: value

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # JSON only: a form of another site (text/plain, urlencoded, multipart)
  # is sent with the person's cookie and no preflight, and is never read.
  def json_request?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] ->
        case Utils.media_type(type) do
          {:ok, "application", subtype, _params} ->
            subtype == "json" or String.ends_with?(subtype, "+json")

          _other ->
            false
        end

      [] ->
        false
    end
  end

  # The request's "uploads": parsed by Plug.Parsers, or read here.
  def items(conn) do
    if json_request?(conn), do: json_items(conn), else: {:unsupported, conn}
  end

  defp json_items(conn) do
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
        "headers" => upload.headers,
        "token" => upload.token
      }
    }

  def result({:existing, file}), do: %{"existing" => Storehouse.File.to_map(file)}
  def result({:error, code}) when is_atom(code), do: %{"error" => Atom.to_string(code)}
  def result({:error, _reason}), do: %{"error" => "upload_failed"}
end
