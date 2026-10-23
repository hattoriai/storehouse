defmodule Storehouse.DedupTest do
  use ExUnit.Case, async: true

  alias Storehouse.Memory

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  setup do
    Memory.checkout()
    body = File.read!(@harbour)
    %{body: body, checksum: Base.encode64(:crypto.hash(:sha256, body))}
  end

  # The app's files by checksum: those given, as a database would answer.
  defp existing(files), do: fn checksum -> Enum.find(files, &(&1.checksum == checksum)) end

  test "the same file stored again is the one kept, and nothing is stored" do
    {:ok, kept} = Storehouse.store(@harbour, adapter: Memory)

    assert Storehouse.store(@harbour, adapter: Memory, existing: existing([kept])) ==
             {:existing, kept}

    assert Memory.keys() == [kept.key]

    # Another file is stored as ever.
    small = Path.expand("../fixtures/small.png", __DIR__)
    assert {:ok, _file} = Storehouse.store(small, adapter: Memory, existing: existing([kept]))
  end

  test "never another owner's file" do
    {:ok, theirs} = Storehouse.store(@harbour, adapter: Memory, owner: 7)

    assert {:ok, mine} =
             Storehouse.store(@harbour, adapter: Memory, owner: 42, existing: existing([theirs]))

    assert Storehouse.owns?(42, mine.key)
  end

  test "a file the app has is not uploaded again", %{body: body, checksum: checksum} do
    {:ok, kept} = Storehouse.store(@harbour, adapter: Memory)
    hex = Base.encode16(Base.decode64!(checksum), case: :lower)

    for claimed <- [checksum, hex] do
      assert Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body),
               adapter: Memory,
               checksum: claimed,
               existing: existing([kept])
             ) == {:existing, kept}
    end

    assert Storehouse.presign_upload("h.jpg", "image/jpeg", 1, adapter: Memory, checksum: "nope") ==
             {:error, :invalid_checksum}
  end

  test "an upload signed with its checksum takes only those bytes", %{body: body, checksum: sum} do
    {:ok, upload} =
      Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body),
        adapter: Memory,
        checksum: sum
      )

    other = binary_part(body, 0, byte_size(body) - 1) <> "x"
    assert Memory.put_upload(upload, other) == 403
    assert Memory.put_upload(upload, body) == 200

    assert {:ok, file} = Storehouse.verify_upload(upload.key, adapter: Memory)
    assert file.checksum == sum
  end

  test "the same file uploaded twice at once: the second is the first, and its copy goes",
       %{body: body} do
    uploads =
      for _n <- 1..2 do
        {:ok, upload} =
          Storehouse.presign_upload("h.jpg", "image/jpeg", byte_size(body), adapter: Memory)

        200 = Memory.put_upload(upload, body)
        upload
      end

    [first, second] = uploads
    {:ok, kept} = Storehouse.verify_upload(first.key, adapter: Memory, existing: existing([]))

    assert Storehouse.verify_upload(second.key, adapter: Memory, existing: existing([kept])) ==
             {:existing, kept}

    assert Memory.keys() == [kept.key]

    # Verifying the file the app has gives it, and deletes nothing.
    assert {:ok, %{key: key}} =
             Storehouse.verify_upload(kept.key, adapter: Memory, existing: existing([kept]))

    assert key == kept.key

    assert Memory.keys() == [kept.key]
  end

  test "telemetry says a file was one the app has" do
    {:ok, kept} = Storehouse.store(@harbour, adapter: Memory)
    ref = :telemetry_test.attach_event_handlers(self(), [[:storehouse, :store, :stop]])

    {:existing, ^kept} = Storehouse.store(@harbour, adapter: Memory, existing: existing([kept]))
    assert_received {[:storehouse, :store, :stop], ^ref, _m, %{result: :existing, file: ^kept}}
  end
end
