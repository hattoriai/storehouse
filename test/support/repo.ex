if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule StorehouseTest.Repo do
    @moduledoc "The repo of Storehouse.Ecto's tests, on PostgreSQL (DATABASE_URL)."
    use Ecto.Repo, otp_app: :storehouse, adapter: Ecto.Adapters.Postgres
  end

  defmodule StorehouseTest.User do
    @moduledoc "A record with files."
    use Ecto.Schema

    schema "storehouse_users" do
      field(:name, :string)
      field(:avatar, Storehouse.Ecto.File)
      field(:photos, {:array, Storehouse.Ecto.File}, default: [])
      field(:invoice, Storehouse.Ecto.File, store: StorehouseTest.PrivateFiles)
    end
  end

  defmodule StorehouseTest.Story do
    @moduledoc "A record whose blocks refer to files of a library, in JSON."
    use Ecto.Schema

    schema "storehouse_stories" do
      field(:title, :string)
      field(:blocks, {:array, :map}, default: [])
    end
  end

  defmodule StorehouseTest.Photo do
    @moduledoc "A library of the app's own: its table, its usages, a column of its own."
    use Storehouse.Ecto.Blob.Schema, usages: "storehouse_test_photo_usages"

    alias Storehouse.Ecto.Blob.Schema, as: BlobSchema

    schema "storehouse_test_photos" do
      BlobSchema.fields()
      field(:alt_text, :string)
    end
  end
end
