if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Storehouse.Live do
    @moduledoc """
    The files of a LiveView upload, stored.

        def mount(_params, _session, socket) do
          {:ok,
           socket
           |> assign(:photos, [])
           |> allow_upload(:photos,
             accept: ~w(.png .jpg .jpeg .gif .webp),
             max_file_size: 10_000_000,
             auto_upload: true,
             progress: &handle_progress/3
           )}
        end

        defp handle_progress(:photos, _entry, socket) do
          {socket, results} = Storehouse.Live.consume(socket, :photos, accept: Storehouse.Check.images())

          socket =
            Enum.reduce(results, socket, fn
              {_entry, {:ok, file}}, socket -> update(socket, :photos, &[file | &1])
              {entry, {:error, reason}}, socket -> put_flash(socket, :error, "\#{entry.client_name}: \#{inspect(reason)}")
            end)

          {:noreply, socket}
        end

    The size limits and the accepted types are the upload's (its `accept`
    and `max_file_size`); each file is checked again on the server, by its
    bytes (`Storehouse.Check`), and `:accept` refuses the types the app does
    not take. See the [LiveView](liveview.md) guide.
    """

    import Phoenix.LiveView, only: [cancel_upload: 3, consume_uploaded_entry: 3]

    alias Phoenix.LiveView.{Socket, UploadConfig, UploadEntry}

    @consumed :storehouse_consumed

    @typedoc "What became of an entry: its stored file, or why it was not stored."
    @type result :: {UploadEntry.t(), {:ok, Storehouse.File.t()} | {:error, term()}}

    @doc """
    Stores the finished entries of `upload_name`, and cancels those the
    upload refused. Gives the socket and a result for each of them, in the
    entries' order.

      * An entry that is done is consumed and stored with
        `Storehouse.store/2` (its name and claimed type are the client's):
        `{:ok, file}`, or `{:error, reason}` when the check or the store
        refuses it.
      * An entry with an error (too large, a type that is not accepted, too
        many files) is cancelled: `{:error, reason}`, the upload's
        (`:too_large`, `:not_accepted`, `:too_many_files`, …).
      * An entry still in progress is left alone, and has no result.

    An entry is consumed once: a call before LiveView has dropped an entry
    that an earlier call consumed leaves it alone. So the function can run
    in the progress callback and in a form's change handler, with files
    that finish at different times.

    The options are those of `Storehouse.store/2`, but `:name` and
    `:content_type`.
    """
    @spec consume(Socket.t(), atom() | String.t(), keyword()) :: {Socket.t(), [result()]}
    def consume(%Socket{} = socket, upload_name, opts \\ []) do
      %UploadConfig{entries: entries} = conf = upload(socket, upload_name)
      opts = Keyword.drop(opts, [:name, :content_type])

      # LiveView drops a consumed entry only when its upload channel has
      # closed, a message later. A second call before that must not consume
      # it again: its channel is gone, and the call would crash the LiveView.
      key = {@consumed, upload_name}
      consumed = Map.get(socket.private, key, MapSet.new())
      refs = MapSet.new(entries, & &1.ref)

      {socket, results, consumed} =
        Enum.reduce(entries, {socket, [], MapSet.intersection(consumed, refs)}, fn entry,
                                                                                   {socket,
                                                                                    results,
                                                                                    consumed} ->
          cond do
            not entry.valid? ->
              reason = conf |> Phoenix.Component.upload_errors(entry) |> List.first(:failed)

              {cancel_upload(socket, upload_name, entry.ref),
               [{entry, {:error, reason}} | results], consumed}

            entry.done? and not MapSet.member?(consumed, entry.ref) ->
              result = consume_uploaded_entry(socket, entry, &{:ok, store(&1, entry, opts)})
              {socket, [{entry, result} | results], MapSet.put(consumed, entry.ref)}

            true ->
              {socket, results, consumed}
          end
        end)

      {%{socket | private: Map.put(socket.private, key, consumed)}, Enum.reverse(results)}
    end

    defp upload(socket, upload_name) do
      case socket.assigns[:uploads] do
        %{^upload_name => %UploadConfig{} = conf} -> conf
        _other -> raise ArgumentError, "no upload allowed for #{inspect(upload_name)}"
      end
    end

    # The consume callback always returns {:ok, _}: a file that could not
    # be stored is still consumed (its temporary file is removed), and the
    # result says what happened.
    defp store(%{path: path}, entry, opts) do
      Storehouse.store(path, [name: entry.client_name, content_type: entry.client_type] ++ opts)
    end
  end
end
