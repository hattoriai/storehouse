if Code.ensure_loaded?(Phoenix.LiveView.UploadWriter) do
  defmodule Storehouse.Live.Writer do
    @moduledoc """
    A LiveView upload writer (`Phoenix.LiveView.UploadWriter`) that streams
    each chunk on to the store as it comes, with no file on the app's disk:
    to S3 in the parts of a multipart upload, to the local disk in its
    place. `Storehouse.Live.allow/3` with `mode: :stream` gives it to the
    upload.

    It checks the file as it comes: its first bytes, once it has them, are
    of the type the browser claimed, of a type taken (`:accept`) and within
    `:max_pixels`, or the upload stops, and nothing of it stays in the
    store. Its checksum is computed on the way.

    It runs in the upload's own process (a LiveView upload channel): a
    file's parts go to the store while the next chunks arrive, and the
    LiveView goes on meanwhile.
    """

    @behaviour Phoenix.LiveView.UploadWriter

    alias Storehouse.Check

    @impl true
    def init(opts) do
      entry = Keyword.fetch!(opts, :entry)
      adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
      type = Check.claimed(entry.client_type)
      name = Storehouse.clean_name(entry.client_name)

      with {:ok, key} <- Storehouse.new_key_for(opts, name, type),
           {:ok, stream} <-
             adapter.stream_open(key, %{name: name, content_type: type, bytes: entry.client_size}) do
        {:ok,
         %{
           adapter: adapter,
           key: key,
           name: name,
           type: type,
           opts: opts,
           stream: stream,
           head: <<>>,
           described: nil,
           hash: :crypto.hash_init(:sha256),
           bytes: 0,
           result: nil
         }}
      end
    end

    @impl true
    def write_chunk(data, state) do
      state = %{
        state
        | hash: :crypto.hash_update(state.hash, data),
          bytes: state.bytes + byte_size(data)
      }

      state = if state.described, do: state, else: %{state | head: state.head <> data}

      with {:ok, state} <- check_head(state, false),
           {:ok, stream} <- state.adapter.stream_write(state.stream, data) do
        {:ok, %{state | stream: stream}}
      else
        {:error, reason} -> {:error, reason, abort(state, reason)}
      end
    end

    @impl true
    def close(%{result: {:error, _refused}} = state, _close), do: {:ok, state}

    def close(state, :done) do
      with {:ok, state} <- check_head(state, true),
           {:ok, url} <- state.adapter.stream_close(state.stream) do
        {:ok, %{state | result: {:ok, file(state, url)}}}
      else
        {:error, reason} -> {:ok, abort(state, reason)}
      end
    end

    def close(state, reason), do: {:ok, abort(state, reason)}

    @impl true
    def meta(state), do: %{storehouse: state.result || {:error, :not_done}}

    # The first bytes, once there are enough of them (or the whole file, at
    # its end): of the type claimed, taken, and within the limits.
    defp check_head(%{described: nil} = state, at_end?) do
      if at_end? or byte_size(state.head) >= Check.head_size() do
        size = if at_end?, do: state.bytes, else: state.opts[:entry].client_size

        with {:ok, description} <- Check.describe_head(state.head, size, state.type, state.opts),
             :ok <- matches(description.content_type, state) do
          {:ok, %{state | described: description, head: <<>>}}
        end
      else
        {:ok, state}
      end
    end

    defp check_head(state, _at_end?), do: {:ok, state}

    defp matches(type, %{type: signed, opts: opts}) do
      cond do
        signed != "application/octet-stream" and type != signed -> {:error, :not_accepted}
        is_list(opts[:accept]) and signed not in opts[:accept] -> {:error, :not_accepted}
        true -> :ok
      end
    end

    defp abort(state, reason) do
      if state.stream, do: state.adapter.stream_abort(state.stream)
      error = if match?({:error, _}, reason), do: reason, else: {:error, reason}
      %{state | stream: nil, result: error}
    end

    defp file(state, url) do
      %Storehouse.File{
        key: state.key,
        url: url,
        name: state.name,
        content_type: state.type,
        bytes: state.bytes,
        width: state.described.width,
        height: state.described.height,
        checksum: state.hash |> :crypto.hash_final() |> Base.encode64()
      }
    end
  end
end
