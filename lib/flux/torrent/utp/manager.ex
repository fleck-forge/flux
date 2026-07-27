defmodule Flux.Torrent.Utp.Manager do
  @moduledoc """
  BEP 29 (uTP) transport — a single, application-wide shared UDP socket (not
  per-torrent or per-peer), matching `Flux.Torrent.Dht`'s singleton
  approach. Demuxes incoming packets to the right `Flux.Torrent.Utp.Socket`
  process by `{remote_ip, remote_port, connection_id}` and is the only
  thing that ever touches the underlying `:gen_udp` socket — a `Socket`
  process sends by asking this `Manager`, never directly.

  v1 scope: **outbound only** — an unsolicited `ST_SYN` (nothing already
  connecting/connected for that address) is just dropped, since inbound uTP
  reachability isn't needed for Flux to download over uTP itself (see
  `Flux.Torrent.Utp.Socket`'s moduledoc for the rest of the simplifications).
  """

  use GenServer
  require Logger

  alias Flux.Torrent.Utp.{Packet, Socket}

  defstruct [:socket, connections: %{}]

  ## Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Connects to `ip`:`port` over uTP, blocking the *caller* (not this
  Manager) until the handshake completes or `timeout` elapses — mirrors
  `:gen_tcp.connect/4`'s synchronous-connect shape so `PeerConnection` can
  branch on transport with minimal special-casing.
  """
  @spec connect(:inet.ip4_address(), :inet.port_number(), timeout()) ::
          {:ok, pid()} | {:error, term()}
  def connect(ip, port, timeout \\ 5000) do
    owner = self()

    case GenServer.call(__MODULE__, {:start_connection, ip, port, owner}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:utp_connected, ^pid} ->
            Process.demonitor(ref, [:flush])
            {:ok, pid}

          {:utp_connect_failed, ^pid, reason} ->
            Process.demonitor(ref, [:flush])
            {:error, reason}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, reason}
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            Socket.close(pid)
            {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The actual bound UDP port (useful when configured with port 0 in tests)."
  def port, do: GenServer.call(__MODULE__, :port)

  @doc false
  def send_packet(dest, binary), do: GenServer.cast(__MODULE__, {:send, dest, binary})

  @doc false
  def unregister(key), do: GenServer.cast(__MODULE__, {:unregister, key})

  ## Server

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 51_414)

    case :gen_udp.open(port, [:binary, active: true]) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket}}

      {:error, reason} ->
        {:ok, %__MODULE__{socket: nil}, {:continue, {:log_open_error, reason, port}}}
    end
  end

  @impl true
  def handle_continue({:log_open_error, reason, port}, state) do
    Logger.warning("Utp.Manager: could not open UDP socket on port #{port} (#{inspect(reason)})")
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, %{socket: nil} = state), do: {:reply, nil, state}
  def handle_call(:port, _from, state), do: {:reply, elem(:inet.port(state.socket), 1), state}

  def handle_call({:start_connection, _ip, _port, _owner}, _from, %{socket: nil} = state) do
    {:reply, {:error, :no_socket}, state}
  end

  def handle_call({:start_connection, ip, port, owner}, _from, state) do
    conn_id_recv = unique_conn_id(state.connections, ip, port)

    case Socket.start_link(
           manager: self(),
           remote: {ip, port},
           conn_id_recv: conn_id_recv,
           owner: owner
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        key = {ip, port, conn_id_recv}
        {:reply, {:ok, pid}, %{state | connections: Map.put(state.connections, key, pid)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp unique_conn_id(connections, ip, port) do
    candidate = :rand.uniform(0xFFFE)

    if Map.has_key?(connections, {ip, port, candidate}),
      do: unique_conn_id(connections, ip, port),
      else: candidate
  end

  @impl true
  def handle_cast({:send, _dest, _binary}, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast({:send, {ip, port}, binary}, state) do
    :gen_udp.send(state.socket, ip, port, binary)
    {:noreply, state}
  end

  def handle_cast({:unregister, key}, state) do
    {:noreply, %{state | connections: Map.delete(state.connections, key)}}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    case Packet.decode(data) do
      {:ok, packet} ->
        route_packet(state, ip, port, packet)

      {:error, _reason} ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    connections = for {key, p} <- state.connections, p != pid, into: %{}, do: {key, p}
    {:noreply, %{state | connections: connections}}
  end

  defp route_packet(state, ip, port, packet) do
    case Map.get(state.connections, {ip, port, packet.connection_id}) do
      nil ->
        # No connection is listening on this id from this address — includes
        # every unsolicited ST_SYN, since v1 never accepts inbound uTP.
        :ok

      pid ->
        send(pid, {:utp_incoming, packet})
    end
  end
end
