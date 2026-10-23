# Ecto

A record keeps its files in its own columns: a map (`jsonb`) of each
file's key, URL, name, type, size, checksum, width and height. No table
of files, no join table: the record has its files, as it has its other
fields.

```elixir
# The migration
alter table(:users) do
  add :avatar, :map
  add :photos, {:array, :map}, default: []
end

# The schema
schema "users" do
  field :name, :string
  field :avatar, Storehouse.Ecto.File
  field :photos, {:array, Storehouse.Ecto.File}, default: []
end
```

## A file in a form

The upload is temporary until the form is saved (`cache: true`), and
`Storehouse.Ecto.put_file/4` puts it in the changeset:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(form: to_form(Accounts.change_user(socket.assigns.user)), avatar: nil)
   |> Storehouse.Live.allow(:avatar,
     accept: ~w(.png .jpg .jpeg .webp),
     max_file_size: 5_000_000,
     cache: true,
     auto_upload: true,
     progress: &handle_progress/3
   )}
end

defp handle_progress(:avatar, _entry, socket) do
  {socket, results} = Storehouse.Live.consume(socket, :avatar, accept: Storehouse.Check.images())

  case results do
    [{_entry, {:ok, file}} | _] -> {:noreply, assign(socket, :avatar, file)}
    _other -> {:noreply, socket}
  end
end

def handle_event("save", %{"user" => params}, socket) do
  case Accounts.update_user(socket.assigns.user, params, socket.assigns.avatar) do
    {:ok, user} -> {:noreply, assign(socket, user: user)}
    {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

```elixir
# Accounts
def update_user(user, attrs, avatar) do
  changeset =
    user
    |> User.changeset(attrs)
    |> then(&if avatar, do: Storehouse.Ecto.put_file(&1, :avatar, avatar, accept: Storehouse.Check.images(), max_bytes: 5_000_000), else: &1)

  Storehouse.Ecto.update(Repo, changeset)
end
```

`put_file/4` checks the file against the field's own limits (an error
of the field, as any validation), and when the record is saved, makes it
permanent: a copy in the store, from its temporary key to its permanent
one, in the save's transaction. A copy that fails is an error of the
field, and the save rolls back.

## Temporary, then permanent

A file uploaded for a form that is never saved stays under the temporary
prefix (`cache/`, `Storehouse.cache_prefix/0`). A lifecycle rule of the
bucket deletes it there after a day, with no job of yours:

```json
{
  "Rules": [
    {"ID": "storehouse-cache", "Status": "Enabled", "Filter": {"Prefix": "cache/"}, "Expiration": {"Days": 1}}
  ]
}
```

On AWS, in the bucket's management; on R2, its object lifecycle rules; on
LocalStack, `awslocal s3api put-bucket-lifecycle-configuration`. With
`Storehouse.Local` (or a store with no lifecycle rules), let
`Storehouse.Cleaner` sweep them:

```elixir
children = [
  MyApp.Repo,
  {Storehouse.Cleaner, sweep: [max_age: 86_400]},
  MyAppWeb.Endpoint
]
```

Making a file permanent can run again: a save that rolled back after it,
tried again with the same upload, finds the permanent file there.

## Replaced and deleted files

`Storehouse.Ecto.update/3` saves, then deletes the files the record no
longer has (replaced, or removed with `put_file(changeset, :avatar,
nil)`); `Storehouse.Ecto.delete/3` deletes the record, then its files.
Deleted only once the database has the change: a save that fails leaves
every file where it was. With `Storehouse.Cleaner` in the app's
supervision tree, a deletion the store fails is tried again
(`Storehouse.delete_later/2`); without it, the files are deleted at once.

Inside a transaction of yours, they are not deleted (the transaction
could still roll back): delete them after it commits.

```elixir
{:ok, user} =
  Repo.transaction(fn ->
    {:ok, user} = Repo.update(changeset)
    # ...
    user
  end)

Storehouse.Ecto.delete_files(Storehouse.Ecto.replaced(changeset, user))
```

## What a column takes

`Storehouse.Ecto.File` casts a `Storehouse.File` only, never a map of a
form's params: a file's key comes from Storehouse, never from a browser,
so that no one puts another's file in their record.

## Metadata of your own

A file keeps metadata of the app's own: a caption, a credit, a
description for readers who cannot see it. Give it when the file is
stored, or put it later, merged with what the file has:

```elixir
{:ok, file} = Storehouse.store(path, metadata: %{caption: "The quay"})

photo
|> change()
|> Storehouse.Ecto.put_metadata(:image, %{"alt" => params["alt"]})
|> Repo.update()

# In a list field, the file by its key.
Storehouse.Ecto.put_metadata(changeset, :photos, file.key, %{"caption" => caption})
```

It goes into the column with the file, so it holds what JSON holds
(`Storehouse.Metadata`): string keys, strings, numbers, booleans, `nil`,
lists and maps. Anything else is an error of the field, with where it is.

Every key of it is the app's. What is read from the file itself (its
size as stored, an image's EXIF) is not metadata but the file's
`:analysis` (see [After the upload](analysis.md)), kept in the column
beside it. A file sent as JSON carries its metadata and not its analysis,
as an EXIF can hold where a photo was taken: `Storehouse.File.to_map/2`
with `analysis:` sends it when the app wants it to.
