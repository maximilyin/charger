import Config

config :charger, Charger.Prices.Cache, source: Charger.Prices.FixtureSource
config :charger, Charger.Chargers.Cache, source: Charger.Chargers.FixtureSource
config :charger, :catalog_page_size, 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :charger, ChargerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pLhe7Dv7EeAuGkCq8Nu0kEB7tiqruweh/eEu6+AzBWvvNiTCJgvQjO6zR3DKtU9T",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
