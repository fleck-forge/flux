defmodule Flux.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  # Mix isn't available at runtime in a release, so bake the build-time env
  # in as a plain compile-time value instead of calling Mix.env() below.
  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Touches :wx directly and crashes when no wx environment is available
    # (headless CI, NO_WX=1, no display) — best-effort only.
    try do
      Desktop.identify_default_locale(FluxWeb.Gettext)
    rescue
      _ -> :ok
    end

    children =
      [
        FluxWeb.Telemetry,
        Flux.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:flux, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:flux, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Flux.PubSub},
        # BitTorrent engine: Registry maps info_hash -> Session.Worker pid
        # (and {:session_sup, download_id} -> Session supervisor pid), the
        # DynamicSupervisor holds one Session per active download, and the
        # PeerListener accepts inbound peer connections so the engine is
        # genuinely bidirectional (not just outbound-leech).
        {Registry, keys: :unique, name: Flux.Torrent.Registry},
        {DynamicSupervisor, name: Flux.Torrent.SessionSupervisor, strategy: :one_for_one},
        {Flux.Torrent.PeerListener,
         port: Application.get_env(:flux, :torrent, [])[:listen_port] || 51413},
        # One DHT node and one shared uTP socket for the whole app (not per
        # torrent) — matches how real clients run exactly one of each.
        {Flux.Torrent.Dht, port: Application.get_env(:flux, :torrent, [])[:dht_port] || 6881},
        # Start to serve requests, typically the last entry
        FluxWeb.Endpoint
      ] ++ desktop_window_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Flux.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      unless @env == :test, do: Flux.Torrent.resume_incomplete_downloads()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FluxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Opens the native desktop window (wxWidgets WebView) pointed at the
  # endpoint above. `desktop` 1.5.3 crashes on boot if wx has no display to
  # attach to, so NO_WX=1 skips the window entirely here (headless dev/CI) —
  # the endpoint keeps running and its URL is logged for manual access.
  defp desktop_window_child do
    if @env != :test and System.get_env("NO_WX") in [nil, "", "0"] do
      [
        {Desktop.Window,
         [
           app: :flux,
           id: FluxWindow,
           title: "Flux",
           size: {1200, 800},
           url: &FluxWeb.Endpoint.url/0
         ]}
      ]
    else
      Logger.info("NO_WX set: skipping native window, running as a plain web endpoint")
      []
    end
  end
end
