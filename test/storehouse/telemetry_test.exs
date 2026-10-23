defmodule Storehouse.TelemetryTest do
  # The :telemetry spans of storing, signing, checking and deleting.
  use ExUnit.Case, async: false

  @fixtures Path.expand("../fixtures", __DIR__)
  @events for name <- [:store, :fetch, :presign_upload, :verify_upload, :delete],
              kind <- [:start, :stop, :exception],
              do: [:storehouse, name, kind]

  setup do
    root =
      Path.join(System.tmp_dir!(), "storehouse-telemetry-#{System.unique_integer([:positive])}")

    Application.put_env(:storehouse, Storehouse.Local,
      root: root,
      secret: String.duplicate("telemetry-", 4)
    )

    test = self()
    id = "storehouse-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      @events,
      fn event, measurements, meta, _config ->
        send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(id)
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)
  end

  test "a file stored: start, then stop with the file and how long it took" do
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "small.png"))

    assert_received {:telemetry, [:storehouse, :store, :start], %{system_time: _},
                     %{name: "small.png", adapter: Storehouse.Local}}

    assert_received {:telemetry, [:storehouse, :store, :stop], %{duration: duration},
                     %{result: :ok, file: ^file}}

    assert duration >= 0
  end

  test "a file refused: stop with the reason" do
    {:error, :not_accepted} =
      Storehouse.store(Path.join(@fixtures, "not-an-image.png"), accept: ["image/png"])

    assert_received {:telemetry, [:storehouse, :store, :stop], _measurements,
                     %{result: :error, reason: :not_accepted, name: "not-an-image.png"}}
  end

  test "an upload signed, checked, and its file deleted" do
    data = File.read!(Path.join(@fixtures, "small.png"))
    {:ok, upload} = Storehouse.presign_upload("a.png", "image/png", byte_size(data))

    assert_received {:telemetry, [:storehouse, :presign_upload, :stop], _measurements,
                     %{result: :ok, key: key, content_type: "image/png", bytes: 77}}

    assert key == upload.key
    {:ok, path} = Storehouse.Local.path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)

    {:ok, _file} = Storehouse.verify_upload(key)

    assert_received {:telemetry, [:storehouse, :verify_upload, :stop], _measurements,
                     %{result: :ok, key: ^key}}

    :ok = Storehouse.delete(key)

    assert_received {:telemetry, [:storehouse, :delete, :stop], _measurements,
                     %{result: :ok, key: ^key}}
  end

  test "a fetch refused, with its address and no query" do
    {:error, :not_allowed} =
      Storehouse.fetch("https://evil.example/a.png?token=secret", hosts: ["example.com"])

    assert_received {:telemetry, [:storehouse, :fetch, :stop], _measurements,
                     %{result: :error, reason: :not_allowed, url: "https://evil.example/a.png"}}
  end
end
