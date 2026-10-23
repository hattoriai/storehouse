defmodule Storehouse.ReprocessTest do
  # Analysis run again over a table's files, a batch at a time. On
  # PostgreSQL (DATABASE_URL).
  use ExUnit.Case, async: false

  @moduletag :ecto

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Mix.Tasks.Storehouse.Reprocess, as: ReprocessTask
  alias StorehouseTest.{Repo, User}

  defmodule Count do
    @moduledoc false
    # A step that reads nothing and counts each time it runs: the side
    # effect a run again must not repeat.
    @behaviour Storehouse.Analyzer

    @impl true
    def needs_file?, do: false

    @impl true
    def analyze(%Storehouse.File{key: key}, nil, _opts) do
      :counters.add(:persistent_term.get(__MODULE__), 1, 1)

      cond do
        key =~ "broken" ->
          {:error, :broken}

        slow = :persistent_term.get({__MODULE__, :slow}, nil) ->
          Process.sleep(slow) && {:ok, %{"n" => 1}}

        true ->
          {:ok, %{"n" => 1}}
      end
    end
  end

  setup do
    Repo.query!("TRUNCATE storehouse_users")
    Repo.query!("TRUNCATE oban_jobs")
    :persistent_term.put(Count, :counters.new(1, []))
    on_exit(fn -> :persistent_term.erase({Count, :slow}) end)
    :ok
  end

  defp counted, do: :counters.get(:persistent_term.get(Count), 1)

  defp file(i),
    do: %Storehouse.File{
      key: "photos/#{i}.png",
      url: "/#{i}.png",
      name: "#{i}.png",
      content_type: "image/png",
      bytes: 1
    }

  defp users(range) do
    range
    |> Enum.map(&%{name: "user #{&1}", avatar: file(&1), photos: []})
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(User, &1))
  end

  defp analyzed?(user), do: Storehouse.File.analyzed(user.avatar, "count") == %{"n" => 1}

  test "ten thousand records, a batch at a time, then nothing the second time" do
    users(1..10_000)
    test = self()

    assert {:ok, %{records: 10_000, files: 10_000, skipped: 0, failed: []}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count],
               now: true,
               max_concurrency: 8,
               on_progress: &send(test, {:batch, &1})
             )

    assert counted() == 10_000
    assert Enum.all?(Repo.all(User), &analyzed?/1)

    # Never more than a batch at a time.
    batches =
      for _ <- 1..20 do
        assert_received {:batch, %{last: _last} = batch}
        batch
      end

    assert List.last(batches).records == 10_000
    refute_received {:batch, _}

    assert {:ok, %{records: 10_000, files: 0, skipped: 10_000}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true)

    assert counted() == 10_000
  end

  test "stopped halfway, it goes on with only what is missing" do
    users(1..2_000)
    :persistent_term.put({Count, :slow}, 1)

    run =
      Task.async(fn ->
        Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true, batch_size: 100)
      end)

    wait_until(fn -> counted() >= 1_000 end)
    Task.shutdown(run, :brutal_kill)

    stopped_at = counted()
    assert stopped_at < 2_000
    :persistent_term.erase({Count, :slow})

    assert {:ok, %{records: 2_000, files: files}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true)

    assert Enum.all?(Repo.all(User), &analyzed?/1)

    # Only what was not saved ran again: at most the files in flight when it stopped.
    assert files <= 2_000 - stopped_at + 4
    assert counted() <= 2_000 + 4
  end

  test ":force runs every file again; a step that fails is named, and tried the next time" do
    users(1..3)

    Repo.insert_all(User, [
      %{name: "broken", avatar: %{file(4) | key: "photos/broken.png"}, photos: []}
    ])

    assert {:ok, %{files: 4, failed: []}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true)

    # A step that fails keeps why: the next run tries it again.
    assert {:ok, %{files: 1, skipped: 3}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true)

    assert {:ok, %{files: 4, skipped: 0}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true, force: true)
  end

  test ":after starts after a primary key, and a query narrows the records" do
    users(1..10)
    [first | _rest] = Repo.all(from(u in User, order_by: u.id))

    assert {:ok, %{records: 9}} =
             Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], now: true, after: first.id)

    assert {:ok, %{records: 1}} =
             Storehouse.Ecto.reprocess(Repo, where(User, name: "user 1"), :avatar, [Count],
               now: true,
               force: true
             )
  end

  test "as jobs of the runner: one a file, and none again while they wait" do
    start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, testing: :manual})
    users(1..50)
    runner = {Storehouse.Runner.Oban, name: StorehouseTest.Oban}

    capture_log(fn ->
      assert {:ok, %{files: 50}} =
               Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], runner: runner)

      assert {:ok, %{files: 50}} =
               Storehouse.Ecto.reprocess(Repo, User, :avatar, [Count], runner: runner)
    end)

    assert Repo.one(from(j in "oban_jobs", select: count())) == 50
    assert counted() == 0
  end

  test "mix storehouse.reprocess" do
    users(1..3)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    ReprocessTask.run(~w(--repo StorehouseTest.Repo --schema StorehouseTest.User --field avatar
                         --step Storehouse.ReprocessTest.Count --now))

    assert_received {:mix_shell, :info, ["3 records, 3 files… (after " <> _]}

    assert_received {:mix_shell, :info,
                     ["3 records: 3 files analyzed, 0 done already, 0 failed."]}

    assert Enum.all?(Repo.all(User), &analyzed?/1)

    assert_raise Mix.Error, ~r/--step/, fn ->
      ReprocessTask.run(
        ~w(--repo StorehouseTest.Repo --schema StorehouseTest.User --field avatar)
      )
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) == :ok and wait_until(fun, tries - 1)
    end
  end
end
