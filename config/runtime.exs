import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/flux start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :flux, FluxWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Installed desktop apps have no shell to export env vars in, so default to
  # a per-user data directory instead of requiring DATABASE_PATH. It can
  # still be overridden (e.g. for a server-mode deployment).
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join([System.get_env("HOME") || System.tmp_dir!(), ".local/share/flux", "flux.db"])

  File.mkdir_p!(Path.dirname(database_path))

  config :flux, Flux.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # Installed desktop apps have no shell to export env vars in, so fall back
  # to a value generated on first run and persisted alongside the database.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        secret_path = Path.join(Path.dirname(database_path), "secret_key_base")

        case File.read(secret_path) do
          {:ok, secret} ->
            secret

          {:error, _} ->
            secret = Base.encode64(:crypto.strong_rand_bytes(48))
            File.write!(secret_path, secret)
            secret
        end
      )

  host = System.get_env("PHX_HOST") || "localhost"

  config :flux, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :flux, FluxWeb.Endpoint,
    url: [host: host],
    # The packaged desktop app is a local-only endpoint for its own native
    # window: bind to loopback and let the OS pick a free port.
    http: [ip: {127, 0, 0, 1}, port: 0],
    server: true,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :flux, FluxWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :flux, FluxWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
