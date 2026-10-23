# The tests of Storehouse.S3 run against a store that speaks S3's API
# (moto, LocalStack, MinIO) at S3_ENDPOINT, and those of Storehouse.Ecto
# against PostgreSQL at DATABASE_URL, as CI does:
#
#     moto_server -p 4566 &
#     S3_ENDPOINT=http://127.0.0.1:4566 DATABASE_URL=postgres://postgres:postgres@localhost/storehouse_test mix test
exclude =
  [
    s3: !System.get_env("S3_ENDPOINT"),
    ecto: !System.get_env("DATABASE_URL"),
    node: !System.find_executable("node")
  ]
  |> Enum.filter(&elem(&1, 1))
  |> Keyword.keys()

if url = System.get_env("DATABASE_URL") do
  Application.put_env(:storehouse, StorehouseTest.Repo, url: url, pool_size: 5, log: false)
  _ = Ecto.Adapters.Postgres.storage_up(Ecto.Repo.Supervisor.parse_url(url))
  {:ok, _pid} = StorehouseTest.Repo.start_link()

  # Oban's table, for the analysis run in Oban jobs.
  defmodule StorehouseTest.ObanMigration do
    use Ecto.Migration
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  Ecto.Migrator.up(StorehouseTest.Repo, 1, StorehouseTest.ObanMigration, log: false)

  StorehouseTest.Repo.query!("""
  CREATE TABLE IF NOT EXISTS storehouse_users (
    id bigserial PRIMARY KEY,
    name text,
    avatar jsonb,
    photos jsonb[] NOT NULL DEFAULT '{}'
  )
  """)
end

{:ok, _memory} = Storehouse.Memory.start_link()

ExUnit.start(exclude: exclude)
