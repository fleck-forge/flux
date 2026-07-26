import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flux, Flux.Repo,
  database: Path.expand("../flux_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :flux, FluxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jz7bpJAa7dnFYKdgoLQkKhEaidAYl11y6YkKHSqW43MhM5JCPvVWbN0uCDYiK2jD",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Bind to a random free port instead of the real default, so the test suite
# never collides with a real torrent client (or another test run) on the
# same machine.
config :flux, :torrent, listen_port: 0, dht_port: 0, utp_port: 0

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
