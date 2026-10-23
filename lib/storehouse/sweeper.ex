defmodule Storehouse.Sweeper do
  @moduledoc """
  Sweeps, every `:every` seconds, on a store with no lifecycle rule (the
  local disk, MinIO):

    * the temporary files of forms never saved: those under the temporary
      prefix (`Storehouse.cache_prefix/0`) older than `:max_age`;
    * the files that expired (`Storehouse.expiring_key/2`), once their
      time has come.

  On several nodes, each sweep runs on one of them at a time.

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {Storehouse.Sweeper, max_age: 86_400},
        MyAppWeb.Endpoint
      ]

  A bucket with lifecycle rules for the prefixes needs none. `sweep/1`
  does the same once, for a scheduled job of the app's.

  ## Options

    * `:max_age` - in seconds. The default is a day.
    * `:every` - in seconds. The default is an hour.
    * `:prefix` - the default is `Storehouse.cache_prefix/0`.
    * `:expiring` - whether expired files are swept. The default is
      `true`.
    * `:adapter` - the store. The default is `Storehouse.adapter/0`.
  """

  use GenServer

  require Logger

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  @doc "Starts the sweeper, registered as `Storehouse.Sweeper`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [:prefix, :adapter, max_age: 86_400, every: 3_600, expiring: true])

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deletes, at once, the files under the temporary prefix that are older
  than `:max_age` seconds, and the files that expired. Gives
  `{:ok, count}`.

  Takes `:max_age` (the default is a day), `:prefix` (the default is
  `Storehouse.cache_prefix/0`), `:expiring` (the default is `true`) and
  `:adapter`.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(opts \\ []) do
    adapter = Keyword.get_lazy(opts, :adapter, &Storehouse.adapter/0)
    prefix = Keyword.get_lazy(opts, :prefix, &Storehouse.cache_prefix/0)
    now = DateTime.utc_now()
    before = DateTime.add(now, -Keyword.get(opts, :max_age, 86_400))

    with {:ok, cached} <-
           swept(adapter, prefix, &(DateTime.compare(&1.modified_at, before) == :lt)),
         {:ok, expired} <- expired(adapter, now, Keyword.get(opts, :expiring, true)),
         do: {:ok, cached + expired}
  end

  defp expired(_adapter, _now, false), do: {:ok, 0}

  defp expired(adapter, now, true) do
    swept(adapter, Storehouse.expiring_prefix(), fn entry ->
      at = Storehouse.expires_at(entry.key)
      at != nil and DateTime.compare(at, now) != :gt
    end)
  end

  defp swept(adapter, prefix, sweep?) do
    :telemetry.span([:storehouse, :sweep], %{prefix: prefix, adapter: adapter}, fn ->
      result =
        with {:ok, entries} <- Storehouse.list(prefix, adapter: adapter) do
          entries
          |> Stream.filter(sweep?)
          |> Stream.map(& &1.key)
          |> Storehouse.delete_keys(adapter)
        end

      {result, %{prefix: prefix, adapter: adapter, result: result}}
    end)
  end

  @impl GenServer
  def init(opts) do
    send(self(), :sweep)
    {:ok, opts}
  end

  @impl GenServer
  def handle_info(:sweep, opts) do
    locked_sweep(opts)
    Process.send_after(self(), :sweep, :timer.seconds(opts[:every]))
    {:noreply, opts}
  end

  def handle_info(_message, opts), do: {:noreply, opts}

  # A sweep runs on one node at a time: on another, it is skipped. One
  # that fails waits for the next.
  defp locked_sweep(opts) do
    lock = {{__MODULE__, :sweep}, self()}

    case :global.trans(lock, fn -> sweep(opts) end, [node() | Node.list()], 0) do
      {:error, reason} ->
        Logger.warning("Storehouse.Sweeper: the sweep failed: #{inspect(reason)}")

      _swept_or_aborted ->
        :ok
    end
  end
end
