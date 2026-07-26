defmodule Flux.Torrent.Session do
  @moduledoc """
  Thin supervisor wrapping one download's `Session.Worker` plus a
  per-session `DynamicSupervisor` for its `PeerConnection`s — a peer crash
  is isolated from session logic (and vice versa), and killing this
  supervisor cleanly tears down every connection for this download.

  Registers itself in `Flux.Torrent.Registry` under `{:session_sup,
  download_id}` so `Flux.Torrent` (the facade) can find and terminate it
  later without needing to track supervisor pids itself.
  """

  use Supervisor

  def start_link(download_id) do
    Supervisor.start_link(__MODULE__, download_id)
  end

  @doc "The `:via` name for this download's peer-connection DynamicSupervisor."
  def peer_sup_name(download_id) do
    {:via, Registry, {Flux.Torrent.Registry, {:peer_sup, download_id}}}
  end

  @impl true
  def init(download_id) do
    Registry.register(Flux.Torrent.Registry, {:session_sup, download_id}, nil)

    children = [
      {DynamicSupervisor, name: peer_sup_name(download_id), strategy: :one_for_one},
      {Flux.Torrent.Session.Worker, download_id}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
