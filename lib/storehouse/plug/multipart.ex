defmodule Storehouse.Plug.Multipart do
  @moduledoc """
  Very large files sent from the browser straight to the store in parts
  (`Storehouse.presign_multipart/4`), for the JavaScript client or a
  frontend of the app's own: JSON endpoints beside `Storehouse.Plug.Presign`.

      # lib/my_app_web/router.ex, behind your authentication
      scope "/files" do
        pipe_through [:api, :require_user]

        forward "/multipart", Storehouse.Plug.Multipart,
          owner: &MyAppWeb.Files.owner/1,
          room: &MyAppWeb.Files.room/1,
          accept: ["video/mp4", "video/quicktime", "application/zip"],
          max_bytes: 20_000_000_000
      end

  Each is a `POST` of JSON:

    * `start` - `{"name", "type", "bytes", "checksum"}`: `{"upload": {"key",
      "upload_id", "part_bytes", "parts"}}`, or `{"existing": file}` for a
      file the app has already.
    * `sign` - `{"key", "upload_id", "parts": [{"number", "checksum"}]}`, up
      to 1,000 parts, each with its SHA-256 in Base64: `{"parts": [{"number",
      "method", "url", "headers"}]}`. The browser `PUT`s each part to its
      `url` with exactly its `headers`.
    * `list` - `{"key", "upload_id"}`: `{"parts": [{"number", "bytes",
      "checksum"}]}`, those the store has, for a browser reloaded halfway.
    * `complete` - `{"key", "upload_id", "bytes", "name"}`: `{"file": file}`
      or `{"existing": file}`, checked as `Storehouse.Plug.Register` checks
      one; `{"error": "missing_parts"}` or `"wrong_size"` (and the upload
      stays) when the store does not have it all.
    * `abort` - `{"key", "upload_id"}`: `{"ok": true}`.

  A key of another owner's is refused with `403` and `{"error":
  "not_owner"}`, so that no one signs or completes another's upload; a
  body that is not the JSON above gives `400`, and a refusal of the file
  `422`, with `{"error": code}`.

  ## Options

    * `:owner`, `:room`, `:existing` - functions of the conn, as for
      `Storehouse.Plug.Presign`.
    * the options of `Storehouse.presign_multipart/4` and
      `Storehouse.complete_multipart/4` (`:accept`, `:max_bytes`,
      `:max_pixels`, `:part_bytes`, `:key`, `:cache`, `:metadata`,
      `:adapter`), as they are.
  """

  @behaviour Plug

  import Plug.Conn

  alias Storehouse.Plug.Batch

  @impl Plug
  def init(opts), do: Batch.init(opts, [])

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: [action]} = conn, opts)
      when action in ~w(start sign list complete abort) do
    case body(conn) do
      {:ok, conn, body} -> act(action, conn, body, Batch.batch_opts(conn, opts))
      {:error, conn} -> Batch.error(conn, 400, :invalid_request)
    end
  end

  def call(%Plug.Conn{path_info: [action]} = conn, _opts)
      when action in ~w(start sign list complete abort),
      do: Batch.error(conn, 405, :method_not_allowed)

  def call(conn, _opts), do: Batch.error(conn, 404, :not_found)

  defp act("start", conn, %{"name" => name, "bytes" => bytes} = body, opts)
       when is_binary(name) and is_integer(bytes) and bytes >= 0 do
    opts = if sum = body["checksum"], do: Keyword.put(opts, :checksum, sum), else: opts

    case Storehouse.presign_multipart(name, body["type"], bytes, opts) do
      {:ok, upload} ->
        Batch.json(conn, 200, %{
          "upload" => Map.new(upload, fn {k, v} -> {Atom.to_string(k), v} end)
        })

      {:existing, file} ->
        Batch.json(conn, 200, %{"existing" => Storehouse.File.to_map(file)})

      {:error, reason} ->
        refused(conn, reason)
    end
  end

  defp act("sign", conn, %{"parts" => parts} = body, opts) when is_list(parts) do
    with {:ok, key, id} <- upload(body, opts),
         {:ok, parts} <- parts(parts),
         {:ok, signed} <- Storehouse.presign_parts(key, id, parts, opts) do
      Batch.json(conn, 200, %{
        "parts" => Enum.map(signed, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
      })
    else
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp act("list", conn, body, opts) do
    with {:ok, key, id} <- upload(body, opts),
         {:ok, parts} <- Storehouse.multipart_parts(key, id, opts) do
      Batch.json(conn, 200, %{
        "parts" => Enum.map(parts, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
      })
    else
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp act("complete", conn, %{"bytes" => bytes} = body, opts) when is_integer(bytes) do
    opts = if is_binary(body["name"]), do: Keyword.put(opts, :name, body["name"]), else: opts

    case upload(body, opts) do
      {:ok, key, id} -> completed(conn, Storehouse.complete_multipart(key, id, bytes, opts))
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp act("abort", conn, body, opts) do
    with {:ok, key, id} <- upload(body, opts),
         :ok <- Storehouse.abort_multipart(key, id, opts) do
      Batch.json(conn, 200, %{"ok" => true})
    else
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp act(_action, conn, _body, _opts), do: Batch.error(conn, 400, :invalid_request)

  defp completed(conn, {:ok, file}),
    do: Batch.json(conn, 200, %{"file" => Storehouse.File.to_map(file)})

  defp completed(conn, {:existing, file}),
    do: Batch.json(conn, 200, %{"existing" => Storehouse.File.to_map(file)})

  defp completed(conn, {:error, reason}), do: refused(conn, reason)

  # The upload a request names, when it is the owner's.
  defp upload(%{"key" => key, "upload_id" => id}, opts) when is_binary(key) and is_binary(id) do
    cond do
      not Storehouse.valid_key?(key) -> {:error, :invalid_request}
      opts[:owner] && not Storehouse.owns?(opts[:owner], key) -> {:error, :not_owner}
      true -> {:ok, key, id}
    end
  end

  defp upload(_body, _opts), do: {:error, :invalid_request}

  defp parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      %{"number" => n} = part, {:ok, acc} when is_integer(n) ->
        {:cont, {:ok, [{n, part["checksum"]} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid_request}}
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp refused(conn, :invalid_request), do: Batch.error(conn, 400, :invalid_request)
  defp refused(conn, :invalid_part), do: Batch.error(conn, 400, :invalid_part)
  defp refused(conn, :invalid_key), do: Batch.error(conn, 400, :invalid_request)
  defp refused(conn, :not_owner), do: Batch.error(conn, 403, :not_owner)
  defp refused(conn, :not_supported), do: Batch.error(conn, 501, :not_supported)
  defp refused(conn, :enoent), do: Batch.error(conn, 404, :not_found)
  defp refused(conn, {:missing_parts, _numbers}), do: Batch.error(conn, 409, :missing_parts)
  defp refused(conn, {:wrong_size, _bytes}), do: Batch.error(conn, 409, :wrong_size)

  defp refused(conn, reason) when is_atom(reason), do: Batch.error(conn, 422, reason)
  defp refused(conn, _reason), do: Batch.error(conn, 502, :upload_failed)

  # The body: parsed by Plug.Parsers, or read here.
  defp body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        with {:ok, raw, conn} <- read_body(conn, length: 1_000_000),
             {:ok, %{} = body} <- Storehouse.JSON.decode(raw) do
          {:ok, conn, body}
        else
          _invalid -> {:error, conn}
        end

      %{} = body ->
        {:ok, conn, body}
    end
  end
end
