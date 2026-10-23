defmodule Storehouse.Memory do
  @moduledoc """
  A `Storehouse.Adapter` that keeps files in memory, for tests: every
  callback, the optional ones too, with no disk, no bucket and no
  container, and each test's files its own, as Ecto's sandbox keeps each
  test's rows.

      # test/test_helper.exs
      {:ok, _pid} = Storehouse.Memory.start_link()
      ExUnit.start()

      # config/test.exs
      config :storehouse, adapter: Storehouse.Memory

      # in a test, or a case template's setup
      setup do
        Storehouse.Memory.checkout()
      end

  ## Whose files

  A process that has called `checkout/0` owns the files it stores, and
  sees only those: two tests run with `async: true` never see each other's
  files, even under the same key. The processes it starts with `Task` see
  them too (they carry it in `$callers`), and any other process once
  `allow/2` lets it. A file a process stores before any checkout goes to a
  space every such process shares. An owner's files go when it exits.

  ## Uploads straight to the store

  `presign_upload/3` gives an upload whose URL no server takes: in a test,
  make the browser's part of it with `put_upload/2`, which takes the bytes
  as the store would, of the signed type and size only.

  ## Failures

  `fail_next/2` makes the next call of a callback give an error, for the
  tests of an app's error paths:

      Storehouse.Memory.fail_next(:delete, :unavailable)
      assert {:error, :unavailable} = Storehouse.delete(key)

  See `Storehouse.Test` for assertions on what was stored.
  """

  @behaviour Storehouse.Adapter

  use GenServer

  alias Storehouse.Check

  @files __MODULE__.Files
  @owners __MODULE__.Owners

  ## The sandbox

  @doc "Starts the store (its tables), once, in `test_helper.exs`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Makes the calling process the owner of the files it stores from now on,
  and of no others. Its files go when it exits. Gives `:ok`, for a
  `setup` block.
  """
  @spec checkout() :: :ok
  def checkout, do: GenServer.call(__MODULE__, {:checkout, self()})

  @doc "Lets `pid` see and store the files of `owner` (a process that checked out)."
  @spec allow(pid(), pid()) :: :ok
  def allow(owner, pid) when is_pid(owner) and is_pid(pid),
    do: GenServer.call(__MODULE__, {:allow, owner, pid})

  @doc """
  The next call of `callback` (`:put`, `:delete`, `:read_range`, …) by the
  calling process's owner gives `{:error, reason}`, or raises for the
  callbacks that do not return errors (`url/1`).
  """
  @spec fail_next(atom(), term()) :: :ok
  def fail_next(callback, reason) when is_atom(callback) do
    :ets.insert(@owners, {{:fail, owner(), callback}, reason})
    :ok
  end

  @doc "The keys of the files the calling process's owner has, in order."
  @spec keys() :: [Storehouse.Adapter.key()]
  def keys do
    owner = owner()

    @files
    |> :ets.match({{owner, :"$1"}, :_})
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  @doc """
  The file stored under `key`: its `:body`, its `:content_type` and its
  `:modified_at`, or `nil`.
  """
  @spec get(Storehouse.Adapter.key()) :: map() | nil
  def get(key) do
    case :ets.lookup(@files, {owner(), key}) do
      [{_key, file}] -> file
      [] -> nil
    end
  end

  @doc """
  The browser's part of an upload `presign_upload/3` signed: stores
  `body` under its key when it is of the signed size, and gives the
  status a bucket would (`200`, or `403` for another size, other bytes
  than the checksum signed, or an upload that expired).
  """
  @spec put_upload(Storehouse.Adapter.upload(), binary()) :: 200 | 403
  def put_upload(%{url: url}, body) when is_binary(body) do
    %URI{path: "/" <> key, query: query} = URI.parse(url)
    params = URI.decode_query(query || "")

    with {bytes, ""} <- Integer.parse(params["bytes"] || ""),
         true <- bytes == byte_size(body),
         {expires, ""} <- Integer.parse(params["expires"] || ""),
         true <- expires >= System.system_time(:second),
         true <- params["checksum"] in [nil, Base.encode64(:crypto.hash(:sha256, body))] do
      write(key, body, params["type"])
      200
    else
      _refused -> 403
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@files, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@owners, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:checkout, pid}, _from, state) do
    Process.monitor(pid)
    :ets.insert(@owners, {pid, pid})
    {:reply, :ok, state}
  end

  def handle_call({:allow, owner, pid}, _from, state) do
    Process.monitor(pid)
    :ets.insert(@owners, {pid, owner_of(owner)})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case :ets.lookup(@owners, pid) do
      [{^pid, ^pid}] ->
        :ets.match_delete(@files, {{pid, :_}, :_})
        :ets.match_delete(@owners, {:_, pid})
        :ets.match_delete(@owners, {{:fail, pid, :_}, :_})

      _allowed ->
        :ets.delete(@owners, pid)
    end

    {:noreply, state}
  end

  # The owner of the calling process: its own checkout, a caller's, an
  # allowance, or the shared space.
  defp owner do
    Enum.find_value([self() | Process.get(:"$callers", [])], :shared, &owned_by/1)
  end

  defp owner_of(pid), do: owned_by(pid) || pid

  defp owned_by(pid) do
    case :ets.lookup(@owners, pid) do
      [{^pid, owner}] -> owner
      [] -> nil
    end
  end

  defp failure(callback) do
    case :ets.take(@owners, {:fail, owner(), callback}) do
      [{_key, reason}] -> {:error, reason}
      [] -> :ok
    end
  end

  defp write(key, body, type) do
    file = %{body: body, content_type: type, modified_at: DateTime.utc_now()}
    :ets.insert(@files, {{owner(), key}, file})
  end

  defp valid(key), do: if(Storehouse.valid_key?(key), do: :ok, else: {:error, :invalid_key})

  defp found(key) do
    case get(key) do
      nil -> {:error, :enoent}
      file -> {:ok, file}
    end
  end

  ## Storehouse.Adapter

  @impl Storehouse.Adapter
  def put(key, path, meta) do
    with :ok <- failure(:put),
         :ok <- valid(key),
         {:ok, body} <- File.read(path) do
      write(key, body, Map.get(meta, :content_type, Check.content_type(Path.extname(key))))
      {:ok, url(key)}
    end
  end

  @impl Storehouse.Adapter
  def url(key) do
    case failure(:url) do
      :ok -> "/memory/" <> key
      {:error, reason} -> raise ArgumentError, "Storehouse.Memory: #{inspect(reason)}"
    end
  end

  @impl Storehouse.Adapter
  def delete(key) do
    with :ok <- failure(:delete), :ok <- valid(key) do
      :ets.delete(@files, {owner(), key})
      :ok
    end
  end

  @impl Storehouse.Adapter
  def presign_upload(key, meta, opts) do
    with :ok <- failure(:presign_upload), :ok <- valid(key) do
      query =
        %{
          "type" => meta.content_type,
          "bytes" => meta.bytes,
          "expires" => System.system_time(:second) + Keyword.get(opts, :expires_in, 600)
        }
        |> then(&if meta[:checksum], do: Map.put(&1, "checksum", meta.checksum), else: &1)
        |> URI.encode_query()

      {:ok,
       %{
         method: "PUT",
         url: "memory:///" <> key <> "?" <> query,
         headers: %{"content-type" => meta.content_type}
       }}
    end
  end

  @impl Storehouse.Adapter
  def signed_url(key, opts) do
    with :ok <- failure(:signed_url), :ok <- valid(key) do
      expires = System.system_time(:second) + Keyword.get(opts, :expires_in, 300)
      {:ok, url(key) <> "?" <> URI.encode_query(%{"expires" => expires})}
    end
  end

  @impl Storehouse.Adapter
  def read_head(key, bytes) do
    with :ok <- failure(:read_head), :ok <- valid(key), {:ok, file} <- found(key) do
      {:ok, binary_part(file.body, 0, min(bytes, byte_size(file.body))), byte_size(file.body)}
    end
  end

  @impl Storehouse.Adapter
  def head(key) do
    with :ok <- failure(:head), :ok <- valid(key), {:ok, file} <- found(key) do
      {:ok,
       %{
         bytes: byte_size(file.body),
         content_type: file.content_type,
         checksum: sha(file),
         modified_at: file.modified_at
       }}
    end
  end

  @impl Storehouse.Adapter
  def read_range(key, first, last) when first >= 0 and last >= first do
    with :ok <- failure(:read_range), :ok <- valid(key), {:ok, %{body: body}} <- found(key) do
      if first >= byte_size(body),
        do: {:ok, ""},
        else: {:ok, binary_part(body, first, min(last - first + 1, byte_size(body) - first))}
    end
  end

  @impl Storehouse.Adapter
  def checksum(key) do
    with :ok <- failure(:checksum), :ok <- valid(key), {:ok, file} <- found(key) do
      {:ok, sha(file)}
    end
  end

  defp sha(%{body: body}), do: Base.encode64(:crypto.hash(:sha256, body))

  @impl Storehouse.Adapter
  def copy(from, to) do
    with :ok <- failure(:copy),
         :ok <- valid(from),
         :ok <- valid(to),
         {:ok, file} <- found(from) do
      :ets.insert(@files, {{owner(), to}, %{file | modified_at: DateTime.utc_now()}})
      :ok
    end
  end

  @impl Storehouse.Adapter
  def list(prefix) do
    with :ok <- failure(:list) do
      owner = owner()

      entries =
        for key <- keys(),
            String.starts_with?(key, prefix),
            [{_key, file}] = :ets.lookup(@files, {owner, key}),
            do: %{key: key, bytes: byte_size(file.body), modified_at: file.modified_at}

      {:ok, entries}
    end
  end

  @impl Storehouse.Adapter
  def delete_many(keys) do
    with :ok <- failure(:delete_many) do
      owner = owner()
      Enum.each(keys, &:ets.delete(@files, {owner, &1}))
    end
  end

  @impl Storehouse.Adapter
  def stream_open(key, meta) do
    with :ok <- failure(:stream_open),
         :ok <- valid(key),
         nil <- get(key) do
      {:ok, %{key: key, type: Map.get(meta, :content_type), data: [], owner: owner()}}
    else
      %{body: _body} -> {:error, :eexist}
      error -> error
    end
  end

  @impl Storehouse.Adapter
  def stream_write(stream, data) do
    with :ok <- failure(:stream_write), do: {:ok, %{stream | data: [stream.data | data]}}
  end

  # Written for the owner that opened it, whichever process closes it.
  @impl Storehouse.Adapter
  def stream_close(%{key: key, type: type, data: data, owner: owner}) do
    with :ok <- failure(:stream_close) do
      file = %{
        body: IO.iodata_to_binary(data),
        content_type: type,
        modified_at: DateTime.utc_now()
      }

      :ets.insert(@files, {{owner, key}, file})
      {:ok, url(key)}
    end
  end

  @impl Storehouse.Adapter
  def stream_abort(_stream), do: :ok
end
