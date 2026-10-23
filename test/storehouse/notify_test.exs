defmodule Storehouse.NotifyTest do
  # The notifier is application config.
  use ExUnit.Case, async: false

  alias Storehouse.Memory
  alias StorehouseTest.Analyzers

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  defmodule Told do
    @moduledoc false
    def told(event, info, pid), do: send(pid, {:told, event, info})
    def raises(_event, _info), do: raise("the app's notifier is broken")
    def topic(%{file: %{key: key}}), do: "files:" <> hd(String.split(key, "/"))
    def topic(%{key: key}), do: "files:" <> hd(String.split(key, "/"))
    def topic(_info), do: nil
  end

  setup do
    Memory.checkout()
    Application.put_env(:storehouse, :notify, {Told, :told, [self()]})
    on_exit(fn -> Application.delete_env(:storehouse, :notify) end)
  end

  test "a file stored, analyzed, a step failed, and deleted" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory, analyze: [Analyzers.NoFile])
    key = file.key

    assert_received {:told, :stored, %{file: %{key: ^key, analysis: analysis}}}
    assert analysis == %{}
    assert_received {:told, :analyzed, %{file: %{key: ^key}, steps: ["no_file"]}}

    {:ok, _file} = Storehouse.analyze(file, [Analyzers.Fail], adapter: Memory)
    assert_received {:told, :failed, %{file: %{key: ^key}, step: "fail", reason: :no_tool}}
    assert_received {:told, :analyzed, %{steps: ["fail"]}}

    # Nothing ran: nothing to tell.
    {:ok, _file} = Storehouse.analyze(file, [Analyzers.NoFile], adapter: Memory)
    refute_received {:told, :analyzed, _info}

    :ok = Storehouse.delete(key, adapter: Memory)
    assert_received {:told, :deleted, %{key: ^key}}

    {:ok, _file} = Storehouse.store(@harbour, adapter: Memory, key: fn _, _ -> "a/1.jpg" end)
    {:ok, 1} = Storehouse.delete_prefix("a/", adapter: Memory)
    assert_received {:told, :deleted, %{prefix: "a/", count: 1}}
  end

  test "an upload straight to the store, once verified" do
    body = File.read!(@harbour)

    {:ok, upload} =
      Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body), adapter: Memory)

    200 = Memory.put_upload(upload, body)
    {:ok, file} = Storehouse.verify_upload(upload.key, adapter: Memory)

    key = file.key
    assert_received {:told, :stored, %{file: %{key: ^key}}}
  end

  test "analysis later is told once the app's function has it" do
    {:ok, file} = Storehouse.store(@harbour, adapter: Memory)

    :ok =
      Storehouse.analyze_later(file, [Analyzers.NoFile],
        adapter: Memory,
        then: {StorehouseTest.Analyzers, :done, [self()]}
      )

    assert {:messages, messages} = Process.info(self(), :messages)
    analyzed_at = Enum.find_index(messages, &match?({:analyzed, _file}, &1))
    told_at = Enum.find_index(messages, &match?({:told, :analyzed, _info}, &1))
    assert analyzed_at < told_at
  end

  test "notify: nil tells nothing, and a notifier that raises breaks nothing" do
    {:ok, _file} = Storehouse.store(@harbour, adapter: Memory, notify: nil)
    refute_received {:told, _event, _info}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _file} =
                 Storehouse.store(@harbour, adapter: Memory, notify: {Told, :raises, []})
      end)

    assert log =~ "the app's notifier is broken"
  end

  test "Storehouse.Notify.PubSub broadcasts on the app's topic" do
    start_supervised!({Phoenix.PubSub, name: StorehouseTest.NotifyPubSub})
    Phoenix.PubSub.subscribe(StorehouseTest.NotifyPubSub, "files:accounts")
    Phoenix.PubSub.subscribe(StorehouseTest.NotifyPubSub, "every-file")

    by_key =
      {Storehouse.Notify.PubSub, :broadcast, [StorehouseTest.NotifyPubSub, {Told, :topic, []}]}

    {:ok, file} =
      Storehouse.store(@harbour,
        adapter: Memory,
        key: fn _, _ -> "accounts/42/harbour.jpg" end,
        notify: by_key
      )

    assert_receive {:storehouse, :stored, %{file: ^file}}

    {:ok, _file} =
      Storehouse.store(@harbour,
        adapter: Memory,
        notify:
          {Storehouse.Notify.PubSub, :broadcast, [StorehouseTest.NotifyPubSub, "every-file"]}
      )

    assert_receive {:storehouse, :stored, %{file: _file}}

    # A topic of nil: nothing broadcast.
    {:ok, _file} = Storehouse.store(@harbour, adapter: Memory, notify: by_key)
    refute_receive {:storehouse, :stored, _info}, 50
  end
end
