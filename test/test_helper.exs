# The tests of Storehouse.S3 run against a store that speaks S3's API
# (moto, LocalStack, MinIO) at S3_ENDPOINT, as CI does:
#
#     moto_server -p 4566 & S3_ENDPOINT=http://127.0.0.1:4566 mix test
exclude = if System.get_env("S3_ENDPOINT"), do: [], else: [:s3]
ExUnit.start(exclude: exclude)
