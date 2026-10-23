defmodule Storehouse.Tus do
  @moduledoc """
  The uploads in progress of `Storehouse.Tus.Plug`: their state, kept in
  ETS by this process, and those that expired, given up every
  `:sweep_every` seconds (their parts deleted from the store).

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        Storehouse.Tus,
        MyAppWeb.Endpoint
      ]

  ETS is one node's: on several nodes behind a load balancer, a client's
  next request can reach another, which does not know its upload. There,
  keep the state in the app's database instead, with a module of
  `Storehouse.Tus.State` given to the plug as `state:`.

  ## Options

    * `:sweep_every` - in seconds. The default is an hour.
  """

  use GenServer

  require Logger

  alias Storehouse.Tus.Plug, as: TusPlug
  alias Storehouse.Tus.State.ETS

  @table __MODULE__

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the process, which owns the table of uploads."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Gives up the uploads of `state` that expired: `{:ok, count}`. The
  process does it every `:sweep_every` seconds, with its own state.
  """
  @spec sweep(module(), keyword()) :: {:ok, non_neg_integer()}
  def sweep(state \\ ETS, opts \\ []) do
    expired = state.expired(DateTime.utc_now())
    Enum.each(expired, &TusPlug.give_up(&1, state, opts))
    {:ok, length(expired)}
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    every = :timer.seconds(Keyword.get(opts, :sweep_every, 3_600))
    Process.send_after(self(), :sweep, every)
    {:ok, %{every: every}}
  end

  @impl GenServer
  def handle_info(:sweep, %{every: every} = state) do
    case sweep() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("Storehouse.Tus: #{count} expired uploads given up")
    end

    Process.send_after(self(), :sweep, every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def table, do: @table
end

defmodule Storehouse.Tus.State do
  @moduledoc """
  Where `Storehouse.Tus.Plug` keeps each upload between requests: its key,
  size, offset, metadata and, on a store of multipart uploads, its parts
  and the bytes not yet a part. `Storehouse.Tus.State.ETS` is the default,
  one node's.

  An upload is a map with an `:id` (`t:upload/0`). Every field of it must
  be kept as it is: in a database, as an Erlang term (`:erlang.term_to_binary/1`,
  in a `bytea` column) beside the id and `expires_at`.
  """

  @typedoc "An upload in progress, as the plug keeps it."
  @type upload :: %{
          required(:id) => String.t(),
          required(:expires_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc "Keeps `upload`, in place of the one with its id."
  @callback put(upload()) :: :ok

  @doc "The upload with `id`, or `nil`."
  @callback get(String.t()) :: upload() | nil

  @doc "Forgets the upload with `id`."
  @callback delete(String.t()) :: :ok

  @doc "The uploads whose `:expires_at` is before `now`."
  @callback expired(now :: DateTime.t()) :: [upload()]
end

defmodule Storehouse.Tus.State.ETS do
  @moduledoc """
  `Storehouse.Tus.State` in ETS, in the table of the `Storehouse.Tus`
  process, which the app starts: one node's.
  """

  @behaviour Storehouse.Tus.State

  @impl true
  def put(%{id: id} = upload) do
    :ets.insert(table!(), {id, upload})
    :ok
  end

  @impl true
  def get(id) do
    case :ets.lookup(table!(), id) do
      [{^id, upload}] -> upload
      [] -> nil
    end
  end

  @impl true
  def delete(id) do
    :ets.delete(table!(), id)
    :ok
  end

  @impl true
  def expired(now) do
    for {_id, upload} <- :ets.tab2list(table!()),
        DateTime.compare(upload.expires_at, now) == :lt,
        do: upload
  end

  defp table! do
    table = Storehouse.Tus.table()

    if :ets.whereis(table) == :undefined,
      do: raise("Storehouse.Tus is not started: add it to the app's supervision tree"),
      else: table
  end
end
