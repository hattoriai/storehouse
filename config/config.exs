import Config

if config_env() == :test do
  config :logger, level: :warning
  # Elixir's JSON where there is one (1.18 and later), else Jason.
  config :phoenix, :json_library, if(Code.ensure_loaded?(JSON), do: JSON, else: Jason)

  config :storehouse, StorehouseTest.Endpoint,
    secret_key_base: String.duplicate("storehouse-test-secret-key-base-", 3),
    live_view: [signing_salt: "storehouse-test-salt"],
    pubsub_server: StorehouseTest.PubSub,
    server: false
end
