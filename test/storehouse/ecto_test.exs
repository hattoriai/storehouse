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
end
