defmodule Flux.Torrent.PeerListener do
  @moduledoc """
  One listener per application (not per torrent): accepts inbound peer
  connections on a single configured TCP port, reads just enough (the
  68-byte handshake) to learn the connecting peer's info_hash, looks up the
  matching `Flux.Torrent.Session.Worker` via `Flux.Torrent.Registry`, and
  hands the socket off to a new `Flux.Torrent.PeerConnection`. Unknown
  info_hashes (no matching session) are dropped.

  This is what makes the engine genuinely bidirectional — without it, we'd
  only ever connect out to peers a tracker gave us, never accept peers who
  got our address from the tracker themselves.

  Handshakes are read and routed synchronously, one at a time, within the
  accept loop itself (not fanned out to per-connection tasks): the
  accepting process is the socket's TCP owner, and handing TCP ownership
  to the new `PeerConnection` process safely requires the CURRENT owner to
  call `:gen_tcp.controlling_process/2` — spawning the handshake work onto
  a different process would just move the ownership problem, not solve it.
  A slow/malicious peer can therefore stall new inbound accepts for up to
  the handshake timeout; acceptable for v1.
  """

  use GenServer
  require Logger

  alias Flux.Torrent.{WireProtocol, PeerConnection}

  @handshake_timeout 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, listen_socket} ->
        {:ok, actual_port} = :inet.port(listen_socket)
        {:ok, acceptor} = Task.start_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{listen_socket: listen_socket, port: actual_port, acceptor: acceptor}}

      {:error, reason} ->
        Logger.warning("PeerListener: could not listen on port #{port} (#{inspect(reason)})")
        {:ok, %{listen_socket: nil, port: nil, acceptor: nil}}
    end
  end

  @doc "The actual bound port (useful when configured with port 0 in tests)."
  def port, do: GenServer.call(__MODULE__, :port)

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handshake_and_route(socket)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("PeerListener: accept failed (#{inspect(reason)})")
        accept_loop(listen_socket)
    end
  end

  defp handshake_and_route(socket) do
    with {:ok, handshake_bin} <- :gen_tcp.recv(socket, 68, @handshake_timeout),
         {:ok, %{info_hash: info_hash, peer_id: peer_id}, ""} <-
           WireProtocol.decode_handshake(handshake_bin),
         [{session_pid, _}] <- Registry.lookup(Flux.Torrent.Registry, info_hash),
         {:ok, opts} <- safe_connection_info(session_pid),
         {:ok, pid} <- PeerConnection.start_link_awaiting_socket(peer_id, opts),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      PeerConnection.socket_ready(pid, socket)
    else
      _ -> :gen_tcp.close(socket)
    end
  rescue
    _ -> :gen_tcp.close(socket)
  end

  defp safe_connection_info(session_pid) do
    {:ok, GenServer.call(session_pid, :connection_info, 5000)}
  catch
    :exit, _ -> :error
  end
end
