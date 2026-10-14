import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :trading_micro, TradingMicro.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "trading_micro_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :trading_micro, TradingMicroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "g5+xpKSppH0eptPNpvEuMNt1qGQuejtwgDn6rRaXAdJ3z5F3oTe6NS48Xd8oo2iV",
  server: false

# No hub in test: the recorder's processes are started by the tests that
# need them, against injected clocks and a nil hub node.
config :trading_micro, TradingMicro.Recorder, enabled: false
config :trading_micro, :hub_node, nil

# app_status's Collector polls the extension every 5s from its own process,
# which owns no sandbox connection; it would race the tests for the pool.
# StatusExtension is tested directly instead.
config :app_status, extension: nil

# In test we don't send emails
config :trading_micro, TradingMicro.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
