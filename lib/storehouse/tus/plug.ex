defmodule Storehouse.Tus.Plug do
  @moduledoc """
  Resumable uploads through the app, by the [tus](https://tus.io) protocol
  (1.0.0): for clients that speak it (Uppy's Tus plugin, tus-js-client,
  the mobile and desktop clients), and for stores the browser cannot send
  to straight (the local disk). A connection lost halfway carries on from
  the last byte the app has.

      # lib/my_app_web/router.ex, behind your authentication
      forward "/files/tus", Storehouse.Tus.Plug,
        owner: &MyAppWeb.Files.owner/1,
        room: &MyAppWeb.Files.room/1,
        accept: ["video/mp4", "video/quicktime"],
        max_bytes: 20_000_000_000,
        then: &MyAppWeb.Files.uploaded/2

  and `Storehouse.Tus` in the app's supervision tree, where the uploads in
  progress are kept. For a browser that can send straight to a bucket,
  `Storehouse.Plug.Multipart` keeps the bytes out of the app altogether.

  ## Extensions

  `creation` (and `creation-with-upload`: the first bytes with the
  `POST`), `termination` (`DELETE`) and `expiration` (`Upload-Expires`;
  an upload not finished in `:expires_in` is given up). `Upload-Metadata`'s
  `filename` and `filetype` (or `name` and `type`) are the file's name and
  claimed type.

  ## Where the bytes go

  On a store of multipart uploads (`Storehouse.S3`), into its multipart
  upload as they come, a part at a time (`:part_bytes`); the bytes past
  the last whole part wait in the upload's state until the next. On
  another (`Storehouse.Local`), into a file of `:dir` on the app's disk,
  stored when it is whole. Either way the file is checked as every upload
  is: its claimed type, size and the owner's room when it is created, its
  type by its first bytes when it is whole, and deleted when it is not
  what it said.

  ## Options

    * `:owner`, `:room`, `:existing` - functions of the conn, as for
      `Storehouse.Plug.Presign`. A request for an upload of another owner
      is answered `404`.
    * `:accept`, `:max_bytes` (sent as `Tus-Max-Size`), `:max_pixels`,
      `:metadata`, `:cache_control`, `:adapter` - as for `Storehouse.store/2`.
    * `:then` - a function of the conn and the stored file, called when
      the upload is whole and checked, that gives the conn: to save the
      file in a record, to send its key in a header.
    * `:expires_in` - seconds an upload has to finish. The default is a
      day.
    * `:max_uploads` - the uploads one owner may have in progress at once:
      another is refused with `429`. The default is 10. Those in progress
      count against the owner's `:room` too, by their sizes. (With a
      `:state` that has `c:Storehouse.Tus.State.owned/1`.)
    * `:part_bytes` - the parts of a multipart upload, at least 5 MiB. The
      default is 8 MiB.
    * `:dir` - the directory of the uploads to a store without multipart
      uploads. The default is `storehouse-tus` in the system's temporary
      directory: on several nodes, one they share.
    * `:state` - where uploads are kept between requests, a module of
      `Storehouse.Tus.State`. The default is `Storehouse.Tus.State.ETS`.

  ## Why not tussle

  `tussle` (a fork of the `tus` package) is a tus server for Elixir with
  storage of its own (the disk, S3 through ExAws). Storehouse writes
  through its own stores instead, with no dependency, and checks a file
  as every other upload is checked; the protocol itself is small.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Storehouse.Plug.Batch

  @version "1.0.0"
  @extensions "creation,creation-with-upload,termination,expiration"
  @offset_type "application/offset+octet-stream"
  @min_part 5 * 1_048_576

  @impl Plug
  def init(opts) do
    {own, opts} =
      Keyword.split(opts, [:then, :expires_in, :part_bytes, :dir, :state, :max_uploads])

    opts |> Batch.init([]) |> Keyword.merge(own)
  end

  @impl Plug
  def call(conn, opts) do
    conn = put_resp_header(conn, "tus-resumable", @version)

    cond do
      conn.method == "OPTIONS" ->
        conn
        |> put_resp_header("tus-version", @version)
        |> put_resp_header("tus-extension", @extensions)
        |> max_size(opts)
        |> respond(204)

      get_req_header(conn, "tus-resumable") != [@version] ->
        conn |> put_resp_header("tus-version", @version) |> respond(412)

      true ->
        route(conn, conn.path_info, opts)
    end
  end

  defp route(%{method: "POST"} = conn, [], opts), do: create(conn, opts)
  defp route(%{method: "HEAD"} = conn, [id], opts), do: with_upload(conn, id, opts, &offset/3)

  defp route(%{method: "PATCH"} = conn, [id], opts),
    do: with_upload(conn, id, opts, &locked_patch/3)

  defp route(%{method: "DELETE"} = conn, [id], opts),
    do: with_upload(conn, id, opts, &terminate/3)

  defp route(conn, _path, _opts), do: respond(conn, 405)

  defp max_size(conn, opts) do
    case opts[:batch][:max_bytes] do
      max when is_integer(max) -> put_resp_header(conn, "tus-max-size", Integer.to_string(max))
      _none -> conn
    end
  end

  # POST: a new upload, its first bytes with it when it has some.
  defp create(conn, opts) do
    batch = Batch.batch_opts(conn, opts)
    metadata = conn |> header("upload-metadata") |> parse_metadata()
    name = Storehouse.clean_name(metadata["filename"] || metadata["name"] || "file")

    claim =
      metadata["filetype"] || metadata["type"] ||
        Storehouse.Check.content_type(Path.extname(name))

    type = Storehouse.Check.claimed(claim)

    with {:ok, length} <- upload_length(conn),
         :ok <- allowed(type, length, batch),
         :ok <- room_left(length, batch, opts),
         {:ok, upload} <- start(name, type, length, metadata, batch, opts) do
      state(opts).put(upload)

      conn =
        conn
        |> put_resp_header("location", location(conn, upload.id))
        |> put_resp_header("upload-expires", http_date(upload.expires_at))

      cond do
        header(conn, "content-type") == @offset_type -> patch(conn, upload, opts, 201)
        # Nothing to send: whole already.
        length == 0 -> written(conn, upload, opts, 201)
        true -> respond(conn, 201)
      end
    else
      {:error, status} -> respond(conn, status)
    end
  end

  defp upload_length(conn) do
    case Integer.parse(header(conn, "upload-length") || "") do
      {length, ""} when length >= 0 -> {:ok, length}
      _deferred_or_not -> {:error, 400}
    end
  end

  defp allowed(type, length, batch) do
    accept = batch[:accept]

    cond do
      is_integer(batch[:max_bytes]) and length > batch[:max_bytes] -> {:error, 413}
      is_integer(batch[:room]) and length > batch[:room] -> {:error, 413}
      is_list(accept) and type not in accept -> {:error, 415}
      true -> :ok
    end
  end

  # The owner's uploads in progress: no more than :max_uploads, and their
  # sizes within its room with this one's.
  defp room_left(length, batch, opts) do
    state = state(opts)
    owner = batch[:owner] && to_string(batch[:owner])

    if owner && Code.ensure_loaded?(state) && function_exported?(state, :owned, 1) do
      pending = state.owned(owner)
      taken = pending |> Enum.map(& &1.length) |> Enum.sum()

      cond do
        length(pending) >= Keyword.get(opts, :max_uploads, 10) -> {:error, 429}
        is_integer(batch[:room]) and length + taken > batch[:room] -> {:error, 413}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp start(name, type, length, metadata, batch, opts) do
    adapter = Keyword.get_lazy(batch, :adapter, &Storehouse.adapter/0)
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    upload = %{
      id: id,
      owner: batch[:owner] && to_string(batch[:owner]),
      name: name,
      type: type,
      length: length,
      offset: 0,
      metadata: metadata,
      # The store it goes to, which a sweep gives it up in.
      adapter: adapter,
      expires_at: DateTime.add(DateTime.utc_now(), Keyword.get(opts, :expires_in, 86_400))
    }

    if length > 0 and Storehouse.supports?(adapter, :multipart_put, 4) do
      with {:ok, key} <- Storehouse.new_key_for(batch, name, type),
           meta = cache(%{name: name, content_type: type, bytes: length}, batch),
           {:ok, upload_id} <- adapter.multipart_start(key, meta) do
        {:ok,
         Map.merge(upload, %{
           mode: :multipart,
           key: key,
           upload_id: upload_id,
           parts: [],
           tail: ""
         })}
      else
        _failed -> {:error, 500}
      end
    else
      dir = Keyword.get_lazy(opts, :dir, fn -> Path.join(System.tmp_dir!(), "storehouse-tus") end)
      :ok = File.mkdir_p(dir)
      path = Path.join(dir, id)
      :ok = File.write(path, "")
      {:ok, Map.merge(upload, %{mode: :file, path: path})}
    end
  end

  defp cache(meta, batch),
    do: if(cc = batch[:cache_control], do: Map.put(meta, :cache_control, cc), else: meta)

  # The upload of a request: the owner's, not expired.
  defp with_upload(conn, id, opts, fun) do
    owner = Batch.batch_opts(conn, opts)[:owner]

    owner = owner && to_string(owner)

    case state(opts).get(id) do
      %{owner: ^owner} = upload ->
        if DateTime.compare(upload.expires_at, DateTime.utc_now()) == :lt,
          do: respond(conn, 410),
          else: fun.(conn, upload, opts)

      _none_or_another_owners ->
        respond(conn, 404)
    end
  end

  defp offset(conn, upload, _opts) do
    conn
    |> put_resp_header("upload-offset", Integer.to_string(upload.offset))
    |> put_resp_header("upload-length", Integer.to_string(upload.length))
    |> put_resp_header("upload-expires", http_date(upload.expires_at))
    |> put_resp_header("cache-control", "no-store")
    |> respond(200)
  end

  # One PATCH of an upload at a time: another at once is refused.
  defp locked_patch(conn, upload, opts) do
    lock = {{__MODULE__, upload.id}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        # Read again inside the lock: another may have just written.
        patch(conn, state(opts).get(upload.id) || upload, opts, 204)
      after
        :global.del_lock(lock, [node()])
      end
    else
      respond(conn, 423)
    end
  end

  # PATCH: bytes at the upload's offset, written as they are read; the
  # offset kept after each, so a connection lost halfway loses none.
  defp patch(conn, upload, opts, status) do
    cond do
      header(conn, "content-type") != @offset_type ->
        respond(conn, 415)

      status == 204 and header(conn, "upload-offset") != Integer.to_string(upload.offset) ->
        conn |> put_resp_header("upload-offset", Integer.to_string(upload.offset)) |> respond(409)

      true ->
        case write(conn, upload, opts) do
          {:ok, conn, upload} -> written(conn, upload, opts, status)
          {:error, conn, code} -> respond(conn, code)
        end
    end
  end

  defp write(conn, upload, opts) do
    case read_body(conn, length: 1_048_576, read_length: 1_048_576) do
      {more, data, conn} when more in [:ok, :more] ->
        conn |> appended(append(upload, data, opts), opts) |> more(more, opts)

      {:error, _reason} ->
        # The client went away: what was written stays, for the next PATCH.
        {:ok, conn, upload}
    end
  end

  # Each piece kept as it is written.
  defp appended(conn, {:ok, upload}, opts) do
    state(opts).put(upload)
    {:ok, conn, upload}
  end

  defp appended(conn, {:error, code}, _opts), do: {:error, conn, code}

  defp more({:ok, conn, upload}, :more, opts), do: write(conn, upload, opts)
  defp more(result, _more, _opts), do: result

  defp append(%{offset: offset, length: length}, data, _opts)
       when offset + byte_size(data) > length,
       do: {:error, 400}

  defp append(%{mode: :file} = upload, data, _opts) do
    case File.write(upload.path, data, [:append]) do
      :ok -> {:ok, %{upload | offset: upload.offset + byte_size(data)}}
      {:error, _reason} -> {:error, 500}
    end
  end

  defp append(%{mode: :multipart} = upload, data, opts) do
    size = max(Keyword.get(opts, :part_bytes, 8 * 1_048_576), @min_part)
    adapter = adapter(opts)
    upload = %{upload | tail: upload.tail <> data, offset: upload.offset + byte_size(data)}
    send_parts(upload, adapter, size)
  end

  # Whole parts out of the tail, each sent to the store.
  defp send_parts(%{tail: tail} = upload, adapter, size) when byte_size(tail) >= size do
    <<part::binary-size(^size), rest::binary>> = tail

    case adapter.multipart_put(upload.key, upload.upload_id, length(upload.parts) + 1, part) do
      {:ok, sent} ->
        send_parts(%{upload | parts: upload.parts ++ [sent], tail: rest}, adapter, size)

      {:error, _reason} ->
        {:error, 502}
    end
  end

  defp send_parts(upload, _adapter, _size), do: {:ok, upload}

  defp written(conn, %{offset: offset, length: length} = upload, opts, status)
       when offset == length do
    case finish(conn, upload, opts) do
      {:ok, file} ->
        state(opts).delete(upload.id)
        conn = conn |> put_resp_header("upload-offset", Integer.to_string(offset))
        conn = if then = opts[:then], do: then.(conn, file), else: conn
        respond(conn, status)

      {:error, reason} ->
        state(opts).delete(upload.id)
        Logger.info("Storehouse.Tus.Plug: an upload was refused: #{inspect(reason)}")
        conn |> put_resp_header("upload-offset", Integer.to_string(offset)) |> respond(422)
    end
  end

  defp written(conn, upload, _opts, status) do
    conn |> put_resp_header("upload-offset", Integer.to_string(upload.offset)) |> respond(status)
  end

  # The whole file, put together and checked.
  defp finish(conn, %{mode: :multipart} = upload, opts) do
    batch = Batch.batch_opts(conn, opts)
    adapter = adapter(opts)

    last =
      if upload.tail == "",
        do: {:ok, upload},
        else: send_last(upload, adapter)

    with {:ok, upload} <- last do
      result =
        Storehouse.complete_multipart(
          upload.key,
          upload.upload_id,
          upload.length,
          verify_opts(batch, upload)
        )

      with {:error, _reason} <- result, do: adapter.multipart_abort(upload.key, upload.upload_id)
      kept(result)
    end
  end

  defp finish(conn, %{mode: :file} = upload, opts) do
    batch = Batch.batch_opts(conn, opts)

    result =
      Storehouse.store(
        upload.path,
        Keyword.merge(verify_opts(batch, upload), content_type: upload.type)
      )

    File.rm(upload.path)
    kept(result)
  end

  defp send_last(upload, adapter) do
    case adapter.multipart_put(
           upload.key,
           upload.upload_id,
           length(upload.parts) + 1,
           upload.tail
         ) do
      {:ok, sent} -> {:ok, %{upload | parts: upload.parts ++ [sent], tail: ""}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kept({:ok, file}), do: {:ok, file}
  defp kept({:existing, file}), do: {:ok, file}
  defp kept({:error, reason}), do: {:error, reason}

  defp verify_opts(batch, upload) do
    batch
    |> Keyword.take([
      :accept,
      :max_bytes,
      :max_pixels,
      :owner,
      :room,
      :existing,
      :metadata,
      :adapter,
      :cache_control
    ])
    |> Keyword.put(:name, upload.name)
  end

  # DELETE: given up, and its bytes with it.
  defp terminate(conn, upload, opts) do
    give_up(upload, state(opts), adapter: adapter(opts))
    respond(conn, 204)
  end

  @doc false
  # An upload's bytes deleted, and its state.
  def give_up(upload, state, opts) do
    case upload do
      %{mode: :multipart} ->
        adapter =
          upload[:adapter] || Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)

        adapter.multipart_abort(upload.key, upload.upload_id)

      %{mode: :file, path: path} ->
        File.rm(path)
    end

    state.delete(upload.id)
  end

  defp adapter(opts), do: Keyword.get_lazy(opts[:batch], :adapter, &Storehouse.adapter/0)
  defp state(opts), do: Keyword.get(opts, :state, Storehouse.Tus.State.ETS)

  defp location(conn, id) do
    base = request_url(%{conn | query_string: ""}) |> String.trim_trailing("/")
    base <> "/" <> id
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # `Upload-Metadata`: `key base64,key2 base64`; a key may have no value.
  defp parse_metadata(nil), do: %{}

  defp parse_metadata(header) do
    for pair <- String.split(header, ",", trim: true),
        [key | value] = String.split(String.trim(pair), " ", parts: 2),
        key != "",
        into: %{} do
      {key, decoded(value)}
    end
  end

  defp decoded([encoded]) do
    case Base.decode64(encoded) do
      {:ok, value} -> value
      :error -> ""
    end
  end

  defp decoded([]), do: ""

  defp http_date(%DateTime{} = at), do: Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")

  defp respond(conn, status), do: conn |> send_resp(status, "") |> halt()
end
