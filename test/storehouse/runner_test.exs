defmodule Storehouse.RunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Storehouse.{Job, Runner}

  defmodule Echo do
    @moduledoc false
    # A worker that tells the test it ran, and fails or raises when asked.
    @behaviour Storehouse.Job

    @impl true
    def perform(%{"to" => to} = args) do
      send(:erlang.list_to_pid(String.to_charlist(to)), {:ran, args})

      case args do
        %{"fail" => true} -> {:error, :asked}
        %{"raise" => true} -> raise "it broke"
        _ok -> :ok
      end
    end
  end

  defp job(args \\ %{}),
    do: Job.new(Echo, Map.put(args, "to", to_string(:erlang.pid_to_list(self()))))

  describe "Storehouse.Job" do
    test "runs its worker, a raise as its error" do
      assert Job.run(job()) == :ok
      assert_received {:ran, _args}
      assert Job.run(job(%{"fail" => true})) == {:error, :asked}
      assert Job.run(job(%{"raise" => true})) == {:error, "it broke"}
    end

    test "as JSON holds it, and back; never a module that is not a worker" do
      job = job()
      map = Job.to_map(job)

      assert map |> Storehouse.JSON.encode!() |> Storehouse.JSON.decode!() |> Job.from_map() ==
               {:ok, job}

      assert Job.from_map(%{map | "worker" => "String"}) == {:error, {:not_a_worker, "String"}}

      assert Job.from_map(%{map | "worker" => "Nope.NeverDefined"}) ==
               {:error, {:no_module, "Nope.NeverDefined"}}

      assert Job.from_map(%{"x" => 1}) == {:error, {:not_a_job, %{"x" => 1}}}
    end

    test "the same work waiting is one job" do
      assert job().unique == job().unique
      refute job().unique == job(%{"other" => 1}).unique
    end
  end

  describe "the runner" do
    test "given, configured, or the default" do
      assert Runner.resolve(:memory) == {Storehouse.Runner.Memory, []}
      assert Runner.resolve(:oban) == {Storehouse.Runner.Oban, []}
      assert Runner.resolve({MyRunner, a: 1}) == {MyRunner, [a: 1]}

      # No Oban instance named Oban runs here.
      assert Runner.resolve(nil) == {Storehouse.Runner.Memory, []}

      Application.put_env(:storehouse, :runner, {MyRunner, b: 2})
      on_exit(fn -> Application.delete_env(:storehouse, :runner) end)
      assert Runner.resolve(nil) == {MyRunner, [b: 2]}
    end

    test "the memory runner runs a job with its caller's callers, and again when it fails" do
      start_supervised!(
        {Storehouse.Runner.Memory, backoff: fn _attempt -> 5 end, max_attempts: 2}
      )

      ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :job, :discarded]])

      capture_log(fn ->
        assert Runner.enqueue(job(%{"fail" => true}), runner: :memory) == :ok
        assert_receive {:ran, _args}, 500
        assert_receive {:ran, _args}, 500

        assert_receive {[:storehouse, :job, :discarded], ^ref, %{attempts: 2}, %{reason: :asked}},
                       500
      end)
    end
  end

  describe "Storehouse.Runner.Oban" do
    @describetag :ecto

    alias Storehouse.Jobs.Mirror
    alias Storehouse.Runner.Oban.Worker
    alias StorehouseTest.{Flaky, MirroredInOban, PrivateFiles, Repo}

    import Ecto.Query

    setup do
      Repo.query!("TRUNCATE oban_jobs")

      root =
        Path.join(System.tmp_dir!(), "storehouse-runner-#{System.unique_integer([:positive])}")

      Application.put_env(:storehouse, PrivateFiles, root: Path.join(root, "p"), url_prefix: "/p")
      Application.put_env(:storehouse_test, Flaky, root: Path.join(root, "f"), url_prefix: "/f")

      on_exit(fn ->
        Application.delete_env(:storehouse, PrivateFiles)
        Application.delete_env(:storehouse_test, Flaky)
        Application.delete_env(:storehouse, Storehouse.Runner.Oban)
        Flaky.up()
        File.rm_rf!(root)
      end)

      :ok
    end

    defp jobs, do: Repo.all(from(j in "oban_jobs", select: %{queue: j.queue, args: j.args}))

    test "a job is an Oban job, on the queue the app's config names, kept once while it waits" do
      start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, testing: :manual})

      Application.put_env(:storehouse, Storehouse.Runner.Oban,
        name: StorehouseTest.Oban,
        queue: :media
      )

      capture_log(fn ->
        assert Runner.enqueue(job(), runner: :oban) == :ok
        assert Runner.enqueue(job(), runner: :oban) == :ok
      end)

      assert [%{queue: "media", args: %{"worker" => "Storehouse.RunnerTest.Echo"}}] = jobs()

      # The runner's own options take the config's place.
      capture_log(fn ->
        :ok = Runner.enqueue(job(%{"n" => 2}), runner: {Storehouse.Runner.Oban, queue: :photos})
      end)

      assert "photos" in Enum.map(jobs(), & &1.queue)
    end

    test "a queue the instance does not run is told once; none in Oban's testing modes" do
      start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, queues: [media: 1]})
      runner = {Storehouse.Runner.Oban, name: StorehouseTest.Oban, queue: :never_run_here}

      assert capture_log(fn -> :ok = Runner.enqueue(job(), runner: runner) end) =~
               "runs no :never_run_here queue"

      assert capture_log(fn -> :ok = Runner.enqueue(job(%{"n" => 2}), runner: runner) end) == ""

      runs = {Storehouse.Runner.Oban, name: StorehouseTest.Oban, queue: :media}
      assert capture_log(fn -> :ok = Runner.enqueue(job(%{"n" => 3}), runner: runs) end) == ""
    end

    test "a job that fails is retried by Oban, and given up at its last attempt" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :job, :discarded]])

      {:ok, _url} =
        PrivateFiles.put("m/a.txt", Path.expand("../fixtures/small.png", __DIR__), %{})

      args = "m/a.txt" |> Mirror.job(PrivateFiles, Flaky) |> Job.to_map()
      Flaky.down()

      assert {:error, :down} = Oban.Testing.perform_job(Worker, args, attempt: 1, max_attempts: 3)
      refute_received {[:storehouse, :job, :discarded], ^ref, _m, _meta}

      capture_log(fn ->
        assert {:error, :down} =
                 Oban.Testing.perform_job(Worker, args, attempt: 3, max_attempts: 3)
      end)

      assert_received {[:storehouse, :job, :discarded], ^ref, %{attempts: 3}, %{reason: :down}}

      Flaky.up()
      assert :ok = Oban.Testing.perform_job(Worker, args, attempt: 2, max_attempts: 3)
      assert {:ok, _head} = Storehouse.head("m/a.txt", adapter: Flaky)

      assert {:cancel, {:not_a_worker, "String"}} =
               Oban.Testing.perform_job(Worker, %{args | "worker" => "String"}, [])
    end

    test "a mirror's copies, in Oban" do
      start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, testing: :inline})

      capture_log(fn ->
        {:ok, file} =
          Storehouse.store(Path.expand("../fixtures/harbour.jpg", __DIR__),
            adapter: MirroredInOban
          )

        assert {:ok, _head} = Storehouse.head(file.key, adapter: Flaky)
      end)
    end

    def archived(result, test), do: send(test, {:archived, result})

    test "an archive made in an Oban job, then the app's function with it" do
      start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, testing: :manual})

      {:ok, _url} =
        PrivateFiles.put("m/a.png", Path.expand("../fixtures/small.png", __DIR__), %{})

      runner = {Storehouse.Runner.Oban, name: StorehouseTest.Oban}

      capture_log(fn ->
        assert :ok =
                 Storehouse.Archive.store_later(
                   [{"a.png", {:stored, "m/a.png"}}],
                   "exports/a.zip",
                   adapter: PrivateFiles,
                   runner: runner,
                   then: {__MODULE__, :archived, [self()]}
                 )
      end)

      assert [%{args: args}] = jobs()
      assert :ok = Oban.Testing.perform_job(Worker, args, [])
      assert_received {:archived, {:ok, %Storehouse.File{key: "exports/a.zip"} = file}}
      assert {:ok, _head} = Storehouse.head(file.key, adapter: PrivateFiles)

      # Made again, it takes its place.
      assert :ok = Oban.Testing.perform_job(Worker, args, [])
      assert_received {:archived, {:ok, _file}}
    end

    test "the default runner when an instance named Oban runs" do
      start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual})
      assert Runner.resolve(nil) == {Storehouse.Runner.Oban, []}
    end
  end
end
