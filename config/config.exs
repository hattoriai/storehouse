import Config

if config_env() == :test do
  config :logger, level: :warning
  config :phoenix, :json_library, JSON

  config :storehouse, StorehouseTest.Endpoint,
    secret_key_base: String.duplicate("storehouse-test-secret-key-base-", 3),
    live_view: [signing_salt: "storehouse-test-salt"],
    pubsub_server: StorehouseTest.PubSub,
    server: false
end
