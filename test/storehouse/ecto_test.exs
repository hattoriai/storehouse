defmodule Storehouse.EctoTest do
  # Files in records: temporary until the record is saved, permanent then,
  # and deleted once nothing has them. On PostgreSQL (DATABASE_URL).
  use ExUnit.Case, async: false

  @moduletag :ecto

  import Ecto.Changeset

  alias StorehouseTest.{Repo, User}

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-ecto-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Storehouse.Local, root: root)
    Repo.query!("TRUNCATE storehouse_users")

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  # An upload of a form: a temporary file.
  defp upload(name), do: elem(Storehouse.store(Path.join(@fixtures, name), cache: true), 1)
  defp there?(root, %Storehouse.File{key: key}), do: File.exists?(Path.join(root, key))

  defp changeset(user, attrs, avatar, opts \\ []) do
    user
    |> cast(attrs, [:name])
    |> Storehouse.Ecto.put_file(:avatar, avatar, opts)
  end

  test "a temporary file is made permanent when the record is saved", %{root: root} do
    cached = upload("harbour.jpg")
    assert Storehouse.cached?(cached)

    assert {:ok, user} =
             Storehouse.Ecto.insert(
               Repo,
               changeset(%User{}, %{name: "Ada"}, cached, accept: ["image/jpeg"])
             )

    refute Storehouse.cached?(user.avatar)
    assert user.avatar.key == String.replace_prefix(cached.key, "cache/", "")
    assert there?(root, user.avatar)
    refute there?(root, cached)

    # As the column has it.
    assert %User{avatar: %Storehouse.File{} = avatar} = Repo.get!(User, user.id)
    assert avatar == user.avatar
  end

  test "a file of a type not taken, or too large, is an error of the field", %{root: root} do
    cached = upload("harbour.jpg")

    changeset = changeset(%User{}, %{}, cached, accept: ["image/png"])

    assert {"is not a type that is accepted", [validation: :storehouse, reason: :not_accepted]} =
             changeset.errors[:avatar]

    assert {"is too large", _} = changeset(%User{}, %{}, cached, max_bytes: 1_000).errors[:avatar]

    assert {"is too large", _} =
             changeset(%User{}, %{}, cached, max_pixels: 1_000).errors[:avatar]

    assert {:error, _changeset} =
             Storehouse.Ecto.insert(Repo, changeset(%User{}, %{}, cached, accept: ["image/png"]))

    # Still temporary: the bucket's rule deletes it.
    assert there?(root, cached)
  end

  test "a save that rolls back can be tried again with the same upload", %{root: root} do
    cached = upload("small.png")

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               {:ok, _user} = Repo.insert(changeset(%User{}, %{}, cached))
               Repo.rollback(:rolled_back)
             end)

    assert Repo.aggregate(User, :count) == 0
    # Made permanent in the transaction that rolled back: tried again, the same.
    assert {:ok, user} = Storehouse.Ecto.insert(Repo, changeset(%User{}, %{}, cached))
    assert there?(root, user.avatar)
  end

  test "a file that cannot be made permanent fails the save, and saves nothing", %{root: root} do
    cached = upload("small.png")
    File.rm!(Path.join(root, cached.key))

    assert {:error, changeset} = Storehouse.Ecto.insert(Repo, changeset(%User{}, %{}, cached))

    assert {"could not be stored", [validation: :storehouse, reason: :enoent]} =
             changeset.errors[:avatar]

    assert Repo.aggregate(User, :count) == 0
  end

  test "a file replaced or removed is deleted once the record is saved", %{root: root} do
    {:ok, user} = Storehouse.Ecto.insert(Repo, changeset(%User{}, %{}, upload("small.png")))
    first = user.avatar

    # Saved again without a change of the file: it stays.
    {:ok, user} = Storehouse.Ecto.update(Repo, change(user, name: "Ada"))
    assert user.avatar == first and there?(root, first)

    {:ok, user} = Storehouse.Ecto.update(Repo, changeset(user, %{}, upload("small.gif")))
    refute there?(root, first)
    assert there?(root, user.avatar)

    second = user.avatar
    {:ok, user} = Storehouse.Ecto.update(Repo, changeset(user, %{}, nil))
    assert user.avatar == nil
    refute there?(root, second)
  end

  test "inside a transaction, the replaced file stays until the app deletes it", %{root: root} do
    {:ok, user} = Storehouse.Ecto.insert(Repo, changeset(%User{}, %{}, upload("small.png")))
    first = user.avatar
    changeset = changeset(user, %{}, upload("small.gif"))

    {:ok, saved} = Repo.transaction(fn -> elem(Storehouse.Ecto.update(Repo, changeset), 1) end)
    assert there?(root, first)

    assert [^first] = Storehouse.Ecto.replaced(changeset, saved)
    :ok = Storehouse.Ecto.delete_files(Storehouse.Ecto.replaced(changeset, saved))
    refute there?(root, first)
  end

  test "a list of files, and a record deleted with its files", %{root: root} do
    photos = [upload("small.png"), upload("small.gif"), upload("small.webp")]

    {:ok, user} =
      %User{}
      |> change()
      |> Storehouse.Ecto.put_file(:photos, photos)
      |> then(&Storehouse.Ecto.insert(Repo, &1))

    assert Enum.all?(user.photos, &(not Storehouse.cached?(&1) and there?(root, &1)))
    [png, gif, webp] = user.photos

    {:ok, user} =
      Storehouse.Ecto.update(
        Repo,
        user |> change() |> Storehouse.Ecto.put_file(:photos, [png, webp])
      )

    refute there?(root, gif)
    assert Repo.get!(User, user.id).photos == [png, webp]

    {:ok, _deleted} = Storehouse.Ecto.delete(Repo, user)
    refute Enum.any?([png, webp], &there?(root, &1))
  end

  test "a form's params never put a file in a record" do
    params = %{
      "avatar" => %{
        "key" => "2026/10/someone-elses.png",
        "url" => "/uploads/x",
        "content_type" => "image/png",
        "bytes" => 1
      }
    }

    changeset = cast(%User{}, params, [:avatar])
    assert {"is invalid", _} = changeset.errors[:avatar]
  end

  test "metadata is kept in the column, and a change to it is a change", %{root: root} do
    {:ok, user} =
      %User{}
      |> changeset(%{name: "Ana"}, upload("harbour.jpg"))
      |> then(&Storehouse.Ecto.insert(Repo, &1))

    assert user.avatar.metadata == %{}

    {:ok, user} =
      user
      |> change()
      |> Storehouse.Ecto.put_metadata(:avatar, %{caption: "The quay", credit: %{name: "Ana"}})
      |> Repo.update()

    loaded = Repo.get!(User, user.id)
    assert loaded.avatar.metadata == %{"caption" => "The quay", "credit" => %{"name" => "Ana"}}
    assert there?(root, loaded.avatar)

    changeset = loaded |> change() |> Storehouse.Ecto.put_metadata(:avatar, %{bad: {1}})
    refute changeset.valid?

    assert [avatar: {_message, [validation: :storehouse, reason: {:invalid_metadata, ["bad"]}]}] =
             changeset.errors

    # A list field, by the file's key.
    {:ok, user} =
      loaded
      |> change()
      |> Storehouse.Ecto.put_file(:photos, [upload("harbour.jpg"), upload("small.png")])
      |> then(&Storehouse.Ecto.update(Repo, &1))

    [_first, second] = user.photos

    {:ok, user} =
      user
      |> change()
      |> Storehouse.Ecto.put_metadata(:photos, second.key, %{alt: "A small square"})
      |> Repo.update()

    assert [%{metadata: %{}}, %{metadata: %{"alt" => "A small square"}}] =
             Repo.get!(User, user.id).photos
  end

  test "a file saved before metadata existed loads with none" do
    {:ok, user} =
      %User{}
      |> changeset(%{name: "Old"}, upload("small.png"))
      |> then(&Storehouse.Ecto.insert(Repo, &1))

    Repo.query!("UPDATE storehouse_users SET avatar = avatar - 'metadata' WHERE id = $1", [
      user.id
    ])

    assert Repo.get!(User, user.id).avatar.metadata == %{}
  end

  describe "analysis" do
    alias StorehouseTest.Analyzers

    test "insert/3 with :analyze saves the results in the column" do
      {:ok, user} =
        %User{}
        |> changeset(%{name: "Ana"}, upload("harbour.jpg"))
        |> then(&Storehouse.Ecto.insert(Repo, &1, analyze: [avatar: [Analyzers.Bytes]]))

      loaded = Repo.get!(User, user.id)
      assert Storehouse.File.analyzed(loaded.avatar, "bytes") == %{"bytes" => 35_367}
    end

    test "update/3 analyzes only the files the save put there" do
      {:ok, user} =
        %User{}
        |> changeset(%{name: "Ana"}, nil)
        |> Storehouse.Ecto.put_file(:photos, [upload("harbour.jpg")])
        |> then(&Storehouse.Ecto.insert(Repo, &1))

      [first] = user.photos

      {:ok, user} =
        user
        |> change()
        |> Storehouse.Ecto.put_file(:photos, [first, upload("small.png")])
        |> then(
          &Storehouse.Ecto.update(Repo, &1, analyze: [photos: [{Analyzers.Bytes, test: self()}]])
        )

      [_first, second] = user.photos
      assert_received {:bytes, key, _path, true}
      assert key == second.key
      refute_received {:bytes, _key, _path, _there}

      assert [kept, analyzed] = Repo.get!(User, user.id).photos
      assert Storehouse.File.analyzed(kept, "bytes") == nil
      assert Storehouse.File.analyzed(analyzed, "bytes")["bytes"] > 0
    end

    test "the results leave what the app changed meanwhile, and a file gone" do
      {:ok, user} =
        %User{}
        |> changeset(%{name: "Ana"}, upload("harbour.jpg"))
        |> then(&Storehouse.Ecto.insert(Repo, &1))

      {:ok, analyzed} = Storehouse.analyze(user.avatar, [Analyzers.NoFile])

      # Meanwhile, a caption.
      {:ok, _user} =
        user
        |> change()
        |> Storehouse.Ecto.put_metadata(:avatar, %{caption: "The quay"})
        |> Repo.update()

      :ok = Storehouse.Ecto.save_analyzed(analyzed, Repo, User, user.id, :avatar)

      avatar = Repo.get!(User, user.id).avatar
      assert avatar.metadata["caption"] == "The quay"
      assert Storehouse.File.analyzed(avatar, "no_file") == %{"ran" => true}

      # The file replaced since: its analysis is not saved on the new one.
      {:ok, user} =
        Repo.get!(User, user.id)
        |> change()
        |> Storehouse.Ecto.put_file(:avatar, upload("small.png"))
        |> then(&Storehouse.Ecto.update(Repo, &1))

      {:ok, stale} = Storehouse.analyze(analyzed, [Analyzers.Skip])
      :ok = Storehouse.Ecto.save_analyzed(stale, Repo, User, user.id, :avatar)
      assert Repo.get!(User, user.id).avatar.metadata == %{}

      # A record deleted.
      {:ok, _deleted} = Storehouse.Ecto.delete(Repo, Repo.get!(User, user.id))
      assert :ok = Storehouse.Ecto.save_analyzed(stale, Repo, User, user.id, :avatar)
    end

    test "with runner: :oban, in a job" do
      start_supervised!({Oban, name: StorehouseTest.Oban, repo: Repo, testing: :inline})

      {:ok, user} =
        %User{}
        |> changeset(%{name: "Ana"}, upload("harbour.jpg"))
        |> then(&Storehouse.Ecto.insert(Repo, &1))

      assert :ok =
               Storehouse.Ecto.analyze_later(Repo, user, :avatar, [Analyzers.Bytes],
                 runner: {Storehouse.Runner.Oban, name: StorehouseTest.Oban}
               )

      assert Storehouse.File.analyzed(Repo.get!(User, user.id).avatar, "bytes") == %{
               "bytes" => 35_367
             }
    end
  end

  test "a record never takes another owner's file" do
    {:ok, theirs} =
      Storehouse.store(Path.join(@fixtures, "small.png"), owner: "accounts/7", cache: true)

    {:ok, mine} =
      Storehouse.store(Path.join(@fixtures, "small.png"), owner: "accounts/42", cache: true)

    changeset = changeset(%User{}, %{name: "Ana"}, theirs, owner: "accounts/42")
    refute changeset.valid?
    assert [avatar: {_message, [validation: :storehouse, reason: :not_owner]}] = changeset.errors

    assert changeset(%User{}, %{name: "Ana"}, mine, owner: "accounts/42").valid?
  end

  describe "a field with a store of its own" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "storehouse-ecto-private-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:storehouse, StorehouseTest.PrivateFiles,
        root: root,
        url_prefix: "/private"
      )

      on_exit(fn ->
        Application.delete_env(:storehouse, StorehouseTest.PrivateFiles)
        File.rm_rf!(root)
      end)

      %{private: root}
    end

    test "its files are made permanent there, and deleted from there", %{
      root: root,
      private: private
    } do
      assert Storehouse.Ecto.store(User, :invoice) == StorehouseTest.PrivateFiles
      assert Storehouse.Ecto.store(User, :avatar) == nil

      {:ok, cached} =
        Storehouse.store(Path.join(@fixtures, "small.png"),
          adapter: StorehouseTest.PrivateFiles,
          cache: true
        )

      {:ok, user} =
        %User{}
        |> change(name: "Ana")
        |> Storehouse.Ecto.put_file(:invoice, cached)
        |> Storehouse.Ecto.put_file(:avatar, upload("small.gif"))
        |> then(&Storehouse.Ecto.insert(Repo, &1))

      refute Storehouse.cached?(user.invoice)
      assert File.exists?(Path.join(private, user.invoice.key))
      refute File.exists?(Path.join(root, user.invoice.key))
      assert there?(root, user.avatar)

      {:ok, _deleted} = Storehouse.Ecto.delete(Repo, user)
      refute File.exists?(Path.join(private, user.invoice.key))
      refute there?(root, user.avatar)
    end
  end
end
