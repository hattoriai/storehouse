defmodule Storehouse.Mirror do
  @moduledoc """
  A store that keeps its files in a primary store and copies them to
  others, its mirrors: to move to another provider without stopping (new
  files go to both, the old ones are copied, then the app reads from the
  new one), or to keep a second copy in another provider or region.

      defmodule MyApp.Media do
        use Storehouse.Mirror, primary: MyApp.S3Media, mirrors: [MyApp.R2Media]
      end

      config :storehouse, adapter: MyApp.Media

  It is a `Storehouse.Adapter`, used wherever a store is:

    * **Writes** go to the primary: a file stored, streamed, uploaded
      straight from a browser (`Storehouse.verify_upload/2`) or promoted.
      Once the primary has it, each mirror is given a copy of it
      (`Storehouse.copy/2`), out of the request.
    * **Deletes** go to the primary, then to each mirror.
    * **Reads**, URLs and uploads straight from a browser are the
      primary's.

  ## A mirror that fails

  A mirror's copy or deletion never fails the primary's: it is a job of
  the app's runner (`Storehouse.Runner`), tried again until the mirror
  answers. With Oban's (`Storehouse.Runner.Oban`), the jobs are kept in
  the database and outlive a deploy; with `Storehouse.Runner.Memory`
  they live in a process of the app's, and those not done when the app
  stops are not done. `Storehouse.copy_prefix/2` (or `mix storehouse.copy`)
  copies what a mirror is missing, and only that, to catch it up.

  ## Moving to another store

    1. Write to both: `use Storehouse.Mirror, primary: Old, mirrors: [New]`.
    2. Copy the files there were: `mix storehouse.copy --from Old --to New`.
    3. Read from the new one: `primary: New, mirrors: [Old]`, while the
       old one is still wanted, then `New` alone.

  ## Options

    * `:primary` - the store files are written to and read from.
    * `:mirrors` - the stores given a copy of each.
    * `:runner` - the runner of its jobs, in place of the app's
      (`Storehouse.Runner`).
  """

  require Logger

  alias Storehouse.Jobs

  defmacro __using__(opts) do
    primary = Keyword.fetch!(opts, :primary)
    mirrors = Keyword.fetch!(opts, :mirrors)
    runner = Keyword.get(opts, :runner)

    quote do
      @behaviour Storehouse.Adapter

      @doc false
      def __mirror__, do: {unquote(primary), unquote(mirrors), [runner: unquote(runner)]}

      @impl true
      def put(key, path, meta), do: Storehouse.Mirror.put(__mirror__(), key, path, meta)
      @impl true
      def url(key), do: Storehouse.Mirror.read(__mirror__(), :url, [key])
      @impl true
      def delete(key), do: Storehouse.Mirror.delete(__mirror__(), key)
      @impl true
      def presign_upload(key, meta, opts),
        do: Storehouse.Mirror.read(__mirror__(), :presign_upload, [key, meta, opts])

      @impl true
      def uploaded(key), do: Storehouse.Mirror.uploaded(__mirror__(), key)
      @impl true
      def signed_url(key, opts),
        do: Storehouse.Mirror.read(__mirror__(), :signed_url, [key, opts])

      @impl true
      def read_head(key, bytes),
        do: Storehouse.Mirror.read(__mirror__(), :read_head, [key, bytes])

      @impl true
      def head(key), do: Storehouse.Mirror.read(__mirror__(), :head, [key])
      @impl true
      def read_range(key, first, last),
        do: Storehouse.Mirror.read(__mirror__(), :read_range, [key, first, last])

      @impl true
      def list(prefix), do: Storehouse.Mirror.read(__mirror__(), :list, [prefix])
      @impl true
      def checksum(key), do: Storehouse.Mirror.read(__mirror__(), :checksum, [key])
      @impl true
      def delete_many(keys), do: Storehouse.Mirror.delete_many(__mirror__(), keys)
      @impl true
      def copy(from, to), do: Storehouse.Mirror.copy(__mirror__(), from, to)
      @impl true
      def stream_open(key, meta), do: Storehouse.Mirror.stream_open(__mirror__(), key, meta)
      @impl true
      def stream_write(stream, data), do: Storehouse.Mirror.stream_write(stream, data)
      @impl true
      def stream_close(stream), do: Storehouse.Mirror.stream_close(stream)
      @impl true
      def stream_abort(stream), do: Storehouse.Mirror.stream_abort(stream)
    end
  end

  @doc false
  # What only the primary answers: reads, URLs, uploads straight to it. A
  # primary without the callback gives `{:error, :not_supported}`.
  def read({primary, _mirrors, _opts}, function, args) do
    if Code.ensure_loaded?(primary) and function_exported?(primary, function, length(args)),
      do: apply(primary, function, args),
      else: {:error, :not_supported}
  end

  @doc false
  def put({primary, _mirrors, _opts} = mirror, key, path, meta) do
    with {:ok, url} <- primary.put(key, path, meta) do
      mirrored(mirror, key)
      {:ok, url}
    end
  end

  @doc false
  def uploaded(mirror, key) do
    mirrored(mirror, key)
    :ok
  end

  @doc false
  def copy({primary, _mirrors, _opts} = mirror, from, to) do
    with :ok <- primary.copy(from, to) do
      mirrored(mirror, to)
      :ok
    end
  end

  @doc false
  def delete({primary, mirrors, opts}, key) do
    with :ok <- primary.delete(key) do
      for store <- mirrors, do: later(Jobs.Delete.job(%{"key" => key}, store), store, opts)
      :ok
    end
  end

  @doc false
  def delete_many({primary, mirrors, opts}, keys) do
    result =
      if function_exported?(primary, :delete_many, 1),
        do: primary.delete_many(keys),
        else: Enum.reduce_while(keys, :ok, &deleted(primary, &1, &2))

    with :ok <- result do
      for store <- mirrors,
          key <- keys,
          do: later(Jobs.Delete.job(%{"key" => key}, store), store, opts)

      :ok
    end
  end

  defp deleted(primary, key, :ok) do
    case primary.delete(key) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc false
  def stream_open({primary, _mirrors, _opts} = mirror, key, meta) do
    with {:ok, stream} <- read(mirror, :stream_open, [key, meta]),
         do: {:ok, %{mirror: mirror, key: key, primary: primary, stream: stream}}
  end

  @doc false
  def stream_write(%{primary: primary, stream: stream} = mirrored, data) do
    with {:ok, stream} <- primary.stream_write(stream, data),
         do: {:ok, %{mirrored | stream: stream}}
  end

  @doc false
  def stream_close(%{primary: primary, stream: stream, mirror: mirror, key: key}) do
    with {:ok, url} <- primary.stream_close(stream) do
      mirrored(mirror, key)
      {:ok, url}
    end
  end

  @doc false
  def stream_abort(%{primary: primary, stream: stream}), do: primary.stream_abort(stream)

  # Each mirror, given a copy of the primary's file.
  defp mirrored({primary, mirrors, opts}, key) do
    for store <- mirrors, do: later(Jobs.Mirror.job(key, primary, store), store, opts)
  end

  @doc false
  # The mirror's copy of the primary's file. Jobs run side by side: when
  # the primary no longer has it, deleted while it was copied, the
  # mirror's copy goes too.
  def sync(key, primary, mirror) do
    case Storehouse.copy(key, from: primary, to: mirror) do
      {:ok, _copied_or_skipped} ->
        if Storehouse.head(key, adapter: primary) == {:error, :enoent},
          do: Storehouse.delete(key, adapter: mirror),
          else: :ok

      {:error, :enoent} ->
        Storehouse.delete(key, adapter: mirror)

      error ->
        error
    end
  end

  # A job of the runner, tried again until the mirror answers; a runner
  # that cannot keep it, or runs it at once and it fails, only logged: a
  # mirror never fails the primary.
  defp later(job, store, opts) do
    case Storehouse.Runner.enqueue(job, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Storehouse.Mirror: #{inspect(store)} failed: #{inspect(reason)}")
        :ok
    end
  end
end
