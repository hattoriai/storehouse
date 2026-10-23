defmodule Storehouse.Jobs.Analyze do
  @moduledoc false
  # A file's analysis steps, then the app's function with the file
  # (`Storehouse.analyze_later/3`). Its arguments hold the file, the steps
  # and the function as an Erlang term, which only the app writes.
  @behaviour Storehouse.Job

  @doc false
  def job(file, steps, opts) do
    term = Base.encode64(:erlang.term_to_binary({file, steps, opts}))
    names = Enum.map(steps, &Storehouse.Analyzer.name/1)

    Storehouse.Job.new(__MODULE__, %{"term" => term},
      unique: "analyze:#{file.key}:#{Enum.join(names, ",")}",
      max_attempts: 5
    )
  end

  @impl Storehouse.Job
  def perform(%{"term" => term}) do
    {file, steps, opts} = term |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    Storehouse.analyze_now(file, steps, opts)
  end
end

defmodule Storehouse.Jobs.Delete do
  @moduledoc false
  # A file, or every file under a prefix, deleted from a store
  # (`Storehouse.delete_later/2`, `Storehouse.delete_prefix_later/2`).
  @behaviour Storehouse.Job

  @doc false
  def job(target, store),
    do: Storehouse.Job.new(__MODULE__, Map.put(target, "store", inspect(store)))

  @impl Storehouse.Job
  def perform(%{"store" => store} = args) do
    with {:ok, store} <- Storehouse.Job.module(store) do
      case args do
        %{"key" => key} -> Storehouse.delete(key, adapter: store)
        %{"prefix" => prefix} -> Storehouse.delete_prefix(prefix, adapter: store)
      end
    end
  end
end

defmodule Storehouse.Jobs.Mirror do
  @moduledoc false
  # A mirror's copy of its primary's file (`Storehouse.Mirror`).
  @behaviour Storehouse.Job

  @doc false
  def job(key, primary, mirror) do
    Storehouse.Job.new(__MODULE__, %{
      "key" => key,
      "primary" => inspect(primary),
      "mirror" => inspect(mirror)
    })
  end

  @impl Storehouse.Job
  def perform(%{"key" => key, "primary" => primary, "mirror" => mirror}) do
    with {:ok, primary} <- Storehouse.Job.module(primary),
         {:ok, mirror} <- Storehouse.Job.module(mirror),
         do: Storehouse.Mirror.sync(key, primary, mirror)
  end
end

defmodule Storehouse.Jobs.Archive do
  @moduledoc false
  # An archive made and stored (`Storehouse.Archive.store_later/3`), then
  # the app's function with it. Its arguments hold the entries and options
  # as an Erlang term, which only the app writes, and never a password,
  # only the function that gives it.
  @behaviour Storehouse.Job

  @doc false
  def job(entries, key, opts) do
    term = Base.encode64(:erlang.term_to_binary({entries, key, opts}))
    Storehouse.Job.new(__MODULE__, %{"term" => term}, unique: "archive:#{key}", max_attempts: 5)
  end

  @impl Storehouse.Job
  def perform(%{"term" => term}) do
    {entries, key, opts} = term |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    Storehouse.Archive.store_now(entries, key, opts)
  end
end

defmodule Storehouse.Jobs.Warm do
  @moduledoc false
  # A file's sizes made before a visitor asks for them
  # (`Storehouse.Responsive.warm_later/3`). Its arguments hold the file,
  # the presets and the options as an Erlang term, which only the app
  # writes.
  @behaviour Storehouse.Job

  @doc false
  def job(file, presets, opts) do
    term = Base.encode64(:erlang.term_to_binary({file, presets, opts}))

    Storehouse.Job.new(__MODULE__, %{"term" => term},
      unique: "warm:#{file.key}:#{Enum.join(presets, ",")}",
      max_attempts: 3
    )
  end

  @impl Storehouse.Job
  def perform(%{"term" => term}) do
    {file, presets, opts} = term |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    with {:ok, _count} <- Storehouse.Responsive.warm(file, presets, opts), do: :ok
  end
end
