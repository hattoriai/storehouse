# The tests of Storehouse.S3 run against a store that speaks S3's API
# (moto, LocalStack, MinIO) at S3_ENDPOINT, and those of Storehouse.Ecto
# against PostgreSQL at DATABASE_URL, as CI does:
#
#     moto_server -p 4566 &
#     S3_ENDPOINT=http://127.0.0.1:4566 DATABASE_URL=postgres://postgres:postgres@localhost/storehouse_test mix test
exclude =
  [s3: !System.get_env("S3_ENDPOINT"), ecto: !System.get_env("DATABASE_URL")]
  |> Enum.filter(&elem(&1, 1))
  |> Keyword.keys()

if url = System.get_env("DATABASE_URL") do
  Application.put_env(:storehouse, StorehouseTest.Repo, url: url, pool_size: 5, log: false)
  _ = Ecto.Adapters.Postgres.storage_up(Ecto.Repo.Supervisor.parse_url(url))
  {:ok, _pid} = StorehouseTest.Repo.start_link()

  StorehouseTest.Repo.query!("""
  CREATE TABLE IF NOT EXISTS storehouse_users (
    id bigserial PRIMARY KEY,
    name text,
    avatar jsonb,
    photos jsonb[] NOT NULL DEFAULT '{}'
  )
  """)
end

ExUnit.start(exclude: exclude)
