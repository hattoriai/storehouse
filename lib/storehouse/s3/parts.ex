defmodule Storehouse.S3.Parts do
  @moduledoc false
  # The parts of a multipart upload on their way to the bucket, in a
  # process of their own: at most `max` at once, while the upload's
  # process (a LiveView upload channel) goes on receiving the next chunks.
  # A part beyond them waits, and so does its sender: the browser's chunks
  # cannot fill the memory faster than the bucket takes them.
  use GenServer

  # Not linked: a channel (a LiveView upload's process) stops when a
  # process linked to it exits, even normally. It watches its owner instead.
  def start(upload, max), do: GenServer.start(__MODULE__, {upload, max, self()})

  # A part to send: returns as soon as it is on its way, or once there is
  # room for it.
  def put(pid, n, body), do: GenServer.call(pid, {:part, n, body}, :infinity)

  # The parts sent, in order, once all are there (or the first error).
  def finish(pid), do: GenServer.call(pid, :finish, :infinity)

  def stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok)

  @impl true
  def init({upload, max, owner}) do
    # The upload's process gone, so are its parts.
    Process.monitor(owner)

    {:ok,
     %{
       upload: upload,
       max: max,
       tasks: %{},
       parts: [],
       waiting: nil,
       finishing: nil,
       error: nil,
       owner: owner
     }}
  end

  @impl true
  def handle_call({:part, _n, _body}, _from, %{error: error} = state) when error != nil,
    do: {:reply, {:error, error}, state}

  def handle_call({:part, n, body}, from, state) do
    if map_size(state.tasks) < state.max,
      do: {:reply, :ok, start(state, n, body)},
      else: {:noreply, %{state | waiting: {from, n, body}}}
  end

  def handle_call(:finish, from, state), do: maybe_finish(%{state | finishing: from})

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | tasks: Map.delete(state.tasks, ref)}

    state =
      case result do
        {:ok, part} -> %{state | parts: [part | state.parts]}
        {:error, reason} -> %{state | error: state.error || reason}
      end

    state =
      case state.waiting do
        {from, n, body} when state.error == nil ->
          GenServer.reply(from, :ok)
          start(%{state | waiting: nil}, n, body)

        {from, _n, _body} ->
          GenServer.reply(from, {:error, state.error})
          %{state | waiting: nil}

        nil ->
          state
      end

    maybe_finish(state)
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    maybe_finish(%{state | tasks: Map.delete(state.tasks, ref), error: state.error || reason})
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, n, body) do
    upload = state.upload
    task = Task.async(fn -> upload.(n, body) end)
    %{state | tasks: Map.put(state.tasks, task.ref, n)}
  end

  defp maybe_finish(%{finishing: nil} = state), do: {:noreply, state}

  defp maybe_finish(%{finishing: from, tasks: tasks} = state) when map_size(tasks) == 0 do
    reply =
      if state.error,
        do: {:error, state.error},
        else: {:ok, Enum.sort_by(state.parts, &elem(&1, 0))}

    GenServer.reply(from, reply)
    {:noreply, %{state | finishing: nil}}
  end

  defp maybe_finish(state), do: {:noreply, state}
end
