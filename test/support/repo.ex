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
    end
  end
end
