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
`Storehouse.Sweeper` sweep them:

```elixir
children = [
  MyApp.Repo,
  {Storehouse.Sweeper, max_age: 86_400},
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
every file where it was. Each deletion is a job of the app's runner,
tried again when the store fails (`Storehouse.delete_later/2`, and
[Work out of the request](background.md)).

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

## A store of the field's own

`store:` keeps a field's files in a store of their own (see "Several
stores" in the Stores guide): made permanent there, deleted from there.

```elixir
field :invoice, Storehouse.Ecto.File, store: MyApp.PrivateFiles
```

`Storehouse.Ecto.store/2` says which store a field has.

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

## A library of files

A column holds a file one record has: an avatar, an invoice. A library
holds files that many records use: a site's photographs, used by its
stories, its pages, its covers, inside their JSON blocks as much as in
their columns, each kept when the story that first used it is deleted.
It is optional, and an app that keeps files in columns never sees it.

Its tables come from a migration of the app's:

```elixir
defmodule MyApp.Repo.Migrations.AddStorehouseBlobs do
  use Ecto.Migration

  def up, do: Storehouse.Ecto.Migrations.up()
  def down, do: Storehouse.Ecto.Migrations.down()
end
```

`storehouse_blobs` holds a row per file: its key, store, owner, type,
size, checksum, width, height, metadata and analysis. `storehouse_usages`
holds which records use each one. A file goes into the library once it
is stored:

```elixir
{:ok, file} = Storehouse.store(upload.path, owner: "sites/#{site.id}")
{:ok, blob} = Storehouse.Ecto.Blob.insert(Repo, file, owner: "sites/#{site.id}")
```

The same file again for the same owner gives `{:existing, blob}`, the row
the library already has, by its checksum. `Storehouse.Ecto.Blob.to_file/1`
gives a row back as a `Storehouse.File`, with its URL, for a page, a
signed URL or its variants.

### Which records use each file

A record says which files it uses now, each time it is saved, in the same
transaction. Ids from a form or a document are checked to be the
owner's first:

```elixir
Repo.transaction(fn ->
  story = Repo.update!(changeset)
  ids = for %{"data" => %{"image_id" => id}} <- story.blocks, do: id
  {:ok, ids} = Storehouse.Ecto.Blob.owned(Repo, ids, "sites/#{story.site_id}")
  {:ok, _} = Storehouse.Ecto.Usage.record(Repo, story, ids)
  story
end)
```

`record/4` replaces the record's set: the files it no longer uses are
let go. A record deleted uses none (`Storehouse.Ecto.Usage.forget/3`). A
record is named by its table and primary key, so the records of any
schema use files, with no column for it. In a changeset,
`Storehouse.Ecto.Blob.validate_owned/5` puts an error on a field of ids
that are not the owner's.

The library can then say what uses each file, and refuse to delete one
that is used:

```elixir
Storehouse.Ecto.Usage.used_by(Repo, blob)
#=> [%{type: "stories", id: "42"}, %{type: "pages", id: "7"}]

Storehouse.Ecto.Usage.delete(Repo, blob)
#=> {:error, {:in_use, [%{type: "stories", id: "42"}, %{type: "pages", id: "7"}]}}
```

Once nothing uses it, `delete/3` deletes the row, and then the file from
its store. The usage table's foreign key refuses, in the database itself,
the deletion of a row that a record uses, so a story that starts to use
a photograph at the moment it is deleted keeps it.

### A table of the app's own

A library with columns of its own (a description, a credit) or table
names of its own has a schema of the app's with the same fields:

```elixir
defmodule MyApp.Photo do
  use Storehouse.Ecto.Blob.Schema, usages: "photo_usages"

  schema "photos" do
    Storehouse.Ecto.Blob.Schema.fields()
    field :alt_text, :string
  end
end
```

with `Storehouse.Ecto.Migrations.up(blobs: "photos", usages: "photo_usages")`
and its columns in its migration, and `schema: MyApp.Photo` given to each
function: `Storehouse.Ecto.Blob.insert(Repo, file, owner: owner, schema:
MyApp.Photo, attrs: %{alt_text: alt})`.
