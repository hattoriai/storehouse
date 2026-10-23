defmodule Storehouse.LibraryTest do
  # A library of files, used by records whose JSON refers to them. On
  # PostgreSQL (DATABASE_URL).
  use ExUnit.Case, async: false

  @moduletag :ecto

  alias Storehouse.Ecto.{Blob, Usage}
  alias StorehouseTest.{Photo, Repo, Story}

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "storehouse-library-#{System.unique_integer([:positive])}")

    Application.put_env(:storehouse, Storehouse.Local, root: root)

    Repo.query!(
      "TRUNCATE storehouse_usages, storehouse_blobs, storehouse_test_photo_usages, storehouse_test_photos, storehouse_stories"
    )

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), owner: "sites/7")
    {:ok, blob} = Blob.insert(Repo, file, owner: "sites/7")
    %{root: root, stored: file, blob: blob}
  end

  defp story(ids) do
    blocks = for id <- ids, do: %{"type" => "photo", "data" => %{"image_id" => id}}
    Repo.insert!(%Story{title: "Harbour", blocks: blocks})
  end

  # The ids a story's blocks refer to, as the app's save would read them.
  defp ids(%Story{blocks: blocks}), do: for(%{"data" => %{"image_id" => id}} <- blocks, do: id)

  describe "Storehouse.Ecto.Blob" do
    test "a file into the library, with what Storehouse knows of it", %{stored: file, blob: blob} do
      assert %Blob{
               key: key,
               store: "Storehouse.Local",
               owner: "sites/7",
               name: "harbour.jpg",
               content_type: "image/jpeg",
               bytes: 35_367,
               width: 1200,
               height: 800
             } = Repo.get!(Blob, blob.id)

      assert key == file.key
      assert blob.checksum == file.checksum
    end

    test "the same file again is the owner's row; another's is another row", %{
      stored: file,
      blob: blob
    } do
      {:ok, again} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), owner: "sites/7")
      assert {:existing, existing} = Blob.insert(Repo, again, owner: "sites/7")
      assert existing.id == blob.id

      {:ok, other} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), owner: "sites/8")
      assert {:ok, theirs} = Blob.insert(Repo, other, owner: "sites/8")
      assert theirs.id != blob.id

      # The same key twice is refused, whoever asks.
      assert {:error, %Ecto.Changeset{}} =
               Blob.insert(Repo, %{file | checksum: nil}, owner: "sites/9")
    end

    test "back to a file, with its URL and analysis" do
      {:ok, file} = Storehouse.store(Path.join(@fixtures, "small.png"), owner: "sites/7")
      {:ok, file} = Storehouse.analyze(file, [Storehouse.Analyzer.Size])
      {:ok, blob} = Blob.insert(Repo, file, owner: "sites/7")

      back = blob.id |> then(&Repo.get!(Blob, &1)) |> Blob.to_file()
      assert back.key == file.key
      assert back.url == Storehouse.url(file.key)
      assert Storehouse.File.analyzed(back, "size") == Storehouse.File.analyzed(file, "size")
    end

    test "ids checked to be the owner's, before a record refers to them", %{blob: blob} do
      {:ok, other} = Storehouse.store(Path.join(@fixtures, "small.png"), owner: "sites/8")
      {:ok, theirs} = Blob.insert(Repo, other, owner: "sites/8")
      unknown = Ecto.UUID.generate()

      assert {:ok, [_]} = Blob.owned(Repo, [blob.id], "sites/7")
      assert {:ok, [_]} = Blob.owned(Repo, [String.upcase(blob.id)], "sites/7")

      assert {:error, {:not_owned, not_owned}} =
               Blob.owned(Repo, [blob.id, theirs.id, unknown, "../../etc"], "sites/7")

      assert Enum.sort(not_owned) == Enum.sort([theirs.id, unknown, "../../etc"])

      changeset =
        {%{}, %{photos: {:array, :string}}}
        |> Ecto.Changeset.cast(%{photos: [blob.id, theirs.id]}, [:photos])
        |> Blob.validate_owned(:photos, Repo, "sites/7")

      assert {"is not a file of yours", ids: [theirs.id]} == changeset.errors[:photos]
    end
  end

  describe "Storehouse.Ecto.Usage" do
    test "a file two records use is deleted once neither does", %{root: root, blob: blob} do
      first = story([blob.id])
      second = story([blob.id])

      assert {:ok, %{added: 1, removed: 0}} = Usage.record(Repo, first, ids(first))
      assert {:ok, %{added: 1, removed: 0}} = Usage.record(Repo, second, ids(second))

      records = [
        %{type: "storehouse_stories", id: "#{first.id}"},
        %{type: "storehouse_stories", id: "#{second.id}"}
      ]

      assert Usage.used_by(Repo, blob) == records
      assert {:error, {:in_use, ^records}} = Usage.delete(Repo, blob)

      # The first stops using it: the second still does.
      first = Repo.update!(Ecto.Changeset.change(first, blocks: []))
      assert {:ok, %{added: 0, removed: 1}} = Usage.record(Repo, first, ids(first))
      assert {:error, {:in_use, [%{id: id}]}} = Usage.delete(Repo, blob)
      assert id == "#{second.id}"

      # The second is deleted.
      Repo.delete!(second)
      assert {:ok, %{removed: 1}} = Usage.forget(Repo, second)
      assert Usage.used_by(Repo, blob.id) == []

      assert {:ok, _deleted} = Usage.delete(Repo, blob)
      assert Repo.get(Blob, blob.id) == nil
      refute File.exists?(Path.join(root, blob.key))
    end

    test "a record's set, replaced at each save" do
      blobs =
        for name <- ["small.png", "small.webp", "turned.jpg"] do
          {:ok, file} = Storehouse.store(Path.join(@fixtures, name), owner: "sites/7")
          {:ok, blob} = Blob.insert(Repo, file, owner: "sites/7")
          blob.id
        end

      [a, b, c] = blobs
      story = story([a, b, a])

      assert {:ok, %{added: 2, removed: 0}} = Usage.record(Repo, story, ids(story))
      assert Usage.used(Repo, story) == Enum.sort([a, b])

      assert {:ok, %{added: 1, removed: 1}} = Usage.record(Repo, story, [b, c])
      assert Usage.used(Repo, story) == Enum.sort([b, c])

      assert {:ok, %{added: 0, removed: 0}} = Usage.record(Repo, story, [c, b])
    end

    test "ids that are no blob change nothing", %{blob: blob} do
      story = story([blob.id])
      {:ok, _} = Usage.record(Repo, story, [blob.id])
      unknown = Ecto.UUID.generate()

      assert {:error, {:unknown, [^unknown]}} = Usage.record(Repo, story, [unknown])
      assert {:error, {:unknown, ["not-an-id"]}} = Usage.record(Repo, story, ["not-an-id"])
      assert Usage.used(Repo, story) == [blob.id]
    end

    test "the database itself refuses to delete a blob a record uses", %{blob: blob} do
      story = story([blob.id])
      {:ok, _} = Usage.record(Repo, story, [blob.id])

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(blob) end
    end

    test "inside the app's transaction, the row goes and the file stays for after", %{
      root: root,
      blob: blob
    } do
      assert {:ok, {:ok, _deleted}} = Repo.transaction(fn -> Usage.delete(Repo, blob) end)
      assert Repo.get(Blob, blob.id) == nil
      assert File.exists?(Path.join(root, blob.key))
    end

    test "a library of the app's own: its table, its usages, its columns" do
      {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), owner: "sites/7")

      assert {:ok, %Photo{alt_text: "The harbour at dusk"} = photo} =
               Blob.insert(Repo, file,
                 owner: "sites/7",
                 schema: Photo,
                 attrs: %{alt_text: "The harbour at dusk"}
               )

      story = story([photo.id])
      assert {:ok, %{added: 1}} = Usage.record(Repo, story, [photo.id], schema: Photo)

      assert Usage.used_by(Repo, photo, schema: Photo) == [
               %{type: "storehouse_stories", id: "#{story.id}"}
             ]

      assert Usage.used(Repo, story) == []

      assert {:error, {:in_use, [_]}} = Usage.delete(Repo, photo, schema: Photo)
      {:ok, _} = Usage.forget(Repo, story, schema: Photo)
      assert {:ok, _deleted} = Usage.delete(Repo, photo, schema: Photo)
    end
  end
end
