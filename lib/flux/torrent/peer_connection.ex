defmodule Flux.Torrent.PeerConnection do
  @moduledoc """
  One GenServer per TCP peer connection (outbound or inbound-accepted).
  Owns the socket, performs the handshake + BEP 10 extended handshake,
  reassembles wire frames from `active: :once` TCP reads, and dispatches
  decoded messages up to the owning `Flux.Torrent.Session.Worker` (via
  `GenServer.cast/2`) for anything that needs cross-peer coordination
  (piece picking, choking). Serving read requests (seeding) is handled
  directly here against `Flux.Torrent.Storage`, since honoring a request
  only depends on this connection's own choke state, not global state.
  """

  use GenServer
  require Logger

  alias Flux.Torrent.{WireProtocol, Storage}

  @keep_alive_interval 90_000
  @handshake_timeout 10_000
  @ut_metadata_name "ut_metadata"
  @our_ut_metadata_id 1

  defstruct [
    :socket,
    :session_pid,
    :storage_pid,
    :info_hash,
    :our_peer_id,
    :remote_peer_id,
    :remote_address,
    :piece_count,
    :our_bitfield,
    :metadata_size,
    :raw_info_bytes,
    am_choking: true,
    am_interested: false,
    peer_choking: true,
    peer_interested: false,
    remote_bitfield: nil,
    peer_extensions: %{},
    recv_buffer: <<>>,
    metadata_buffer: %{},
    keep_alive_ref: nil
  ]

  ## Client API

  @doc """
  Starts an outbound connection to `address:port`. `opts` must include
  `:info_hash`, `:our_peer_id`, `:session_pid`, `:storage_pid` (may be
  `nil` if metadata isn't known yet — serving is impossible until it is),
  `:piece_count` (may be `nil` pre-metadata), `:our_bitfield` (wire bytes
  or `nil`), and optionally `:raw_info_bytes`/`:metadata_size` (to serve
  ut_metadata to peers once we have it).
  """
  def start_link_outbound(address, port, opts) do
    GenServer.start_link(__MODULE__, {:outbound, address, port, opts})
  end

  @doc "Starts a connection wrapping an already-accepted inbound socket."
  def start_link_inbound(socket, opts) do
    GenServer.start_link(__MODULE__, {:inbound, socket, opts})
  end

  @doc """
  Starts a connection for an inbound socket whose handshake has ALREADY
  been read and validated by `Flux.Torrent.PeerListener` (which needs the
  info_hash before it can even know which session to route to, so it reads
  the handshake itself rather than handing a still-unread socket over).
  """
  def start_link_inbound_prehandshaked(socket, remote_peer_id, opts) do
    GenServer.start_link(__MODULE__, {:inbound_prehandshaked, socket, remote_peer_id, opts})
  end

  @doc "Sends a raw wire message (already encoded via `WireProtocol.encode_message/1`)."
  def send_message(pid, message), do: GenServer.cast(pid, {:send, message})

  @doc "Updates the metadata (info_hash's raw bytes + piece layout) once resolved."
  def metadata_resolved(pid, raw_info_bytes, piece_count, storage_pid) do
    GenServer.cast(pid, {:metadata_resolved, raw_info_bytes, piece_count, storage_pid})
  end

  @doc "Requests BEP 9 metadata piece `piece_index` from this peer (once they've advertised ut_metadata support)."
  def request_metadata_piece(pid, piece_index) do
    GenServer.cast(pid, {:request_metadata_piece, piece_index})
  end

  def close(pid), do: GenServer.stop(pid, :normal)

  ## Server

  @impl true
  def init({:outbound, address, port, opts}) do
    with {:ok, socket} <-
           :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw], @handshake_timeout) do
      state = build_state(socket, opts)
      do_outbound_handshake(state)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:inbound, socket, opts}) do
    state = build_state(socket, opts)
    do_inbound_handshake(state)
  end

  def init({:inbound_prehandshaked, socket, remote_peer_id, opts}) do
    state = %{build_state(socket, opts) | remote_peer_id: remote_peer_id}
    handshake = WireProtocol.encode_handshake(state.info_hash, state.our_peer_id, extended_reserved())

    case :gen_tcp.send(socket, handshake) do
      :ok -> finish_handshake(state)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp build_state(socket, opts) do
    %__MODULE__{
      socket: socket,
      session_pid: Keyword.fetch!(opts, :session_pid),
      storage_pid: Keyword.get(opts, :storage_pid),
      info_hash: Keyword.fetch!(opts, :info_hash),
      our_peer_id: Keyword.fetch!(opts, :our_peer_id),
      piece_count: Keyword.get(opts, :piece_count),
      our_bitfield: Keyword.get(opts, :our_bitfield),
      raw_info_bytes: Keyword.get(opts, :raw_info_bytes),
      metadata_size: Keyword.get(opts, :metadata_size)
    }
  end

  defp do_outbound_handshake(state) do
    handshake = WireProtocol.encode_handshake(state.info_hash, state.our_peer_id, extended_reserved())

    with :ok <- :gen_tcp.send(state.socket, handshake),
         {:ok, remote_handshake_bin} <- :gen_tcp.recv(state.socket, 68, @handshake_timeout),
         {:ok, %{info_hash: remote_info_hash, peer_id: peer_id}, ""} <-
           WireProtocol.decode_handshake(remote_handshake_bin) do
      if remote_info_hash == state.info_hash do
        finish_handshake(%{state | remote_peer_id: peer_id})
      else
        {:stop, :info_hash_mismatch}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp do_inbound_handshake(state) do
    with {:ok, handshake_bin} <- :gen_tcp.recv(state.socket, 68, @handshake_timeout),
         {:ok, %{info_hash: info_hash, peer_id: peer_id}, ""} <-
           WireProtocol.decode_handshake(handshake_bin),
         true <- info_hash == state.info_hash || {:error, :info_hash_mismatch} do
      handshake = WireProtocol.encode_handshake(state.info_hash, state.our_peer_id, extended_reserved())

      with :ok <- :gen_tcp.send(state.socket, handshake) do
        finish_handshake(%{state | remote_peer_id: peer_id})
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp extended_reserved, do: WireProtocol.set_extension_bit(<<0, 0, 0, 0, 0, 0, 0, 0>>)

  defp finish_handshake(state) do
    send_extended_handshake(state)
    if state.our_bitfield, do: send_wire(state, {:bitfield, state.our_bitfield})

    :ok = :inet.setopts(state.socket, active: :once)
    ref = schedule_keep_alive()
    GenServer.cast(state.session_pid, {:peer_connected, self(), state.remote_peer_id})
    {:ok, %{state | keep_alive_ref: ref}}
  end

  defp send_extended_handshake(state) do
    payload =
      WireProtocol.encode_extended_handshake(%{@ut_metadata_name => @our_ut_metadata_id}, state.metadata_size)

    :gen_tcp.send(state.socket, payload)
  end

  defp schedule_keep_alive do
    Process.send_after(self(), :send_keep_alive, @keep_alive_interval)
  end

  @impl true
  def handle_cast({:send, message}, state) do
    send_wire(state, message)
    {:noreply, update_local_state(state, message)}
  end

  def handle_cast({:metadata_resolved, raw_info_bytes, piece_count, storage_pid}, state) do
    {:noreply,
     %{state | raw_info_bytes: raw_info_bytes, piece_count: piece_count, storage_pid: storage_pid}}
  end

  def handle_cast({:request_metadata_piece, piece_index}, state) do
    peer_ext_id = Map.get(state.peer_extensions, @ut_metadata_name)

    if peer_ext_id do
      payload = WireProtocol.encode_ut_metadata_request(peer_ext_id, piece_index)
      :gen_tcp.send(state.socket, payload)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = %{state | recv_buffer: state.recv_buffer <> data}
    state = process_buffer(state)
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: disconnect(state, :tcp_closed)
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state), do: disconnect(state, reason)

  def handle_info(:send_keep_alive, state) do
    send_wire(state, :keep_alive)
    {:noreply, %{state | keep_alive_ref: schedule_keep_alive()}}
  end

  defp disconnect(state, reason) do
    GenServer.cast(state.session_pid, {:peer_disconnected, state.remote_peer_id, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  defp process_buffer(state) do
    case WireProtocol.decode_message(state.recv_buffer) do
      {:ok, message, rest} ->
        state = handle_wire_message(message, %{state | recv_buffer: rest})
        process_buffer(state)

      {:incomplete, _buffer} ->
        state

      {:error, reason} ->
        Logger.warning("PeerConnection: dropping malformed message (#{inspect(reason)})")
        %{state | recv_buffer: <<>>}
    end
  end

  defp handle_wire_message(:keep_alive, state), do: state

  defp handle_wire_message(:choke, state) do
    notify(state, {:peer_choked, state.remote_peer_id})
    %{state | peer_choking: true}
  end

  defp handle_wire_message(:unchoke, state) do
    notify(state, {:peer_unchoked, state.remote_peer_id})
    %{state | peer_choking: false}
  end

  defp handle_wire_message(:interested, state) do
    notify(state, {:peer_interested, state.remote_peer_id})
    %{state | peer_interested: true}
  end

  defp handle_wire_message(:not_interested, state) do
    notify(state, {:peer_not_interested, state.remote_peer_id})
    %{state | peer_interested: false}
  end

  defp handle_wire_message({:have, index}, state) do
    notify(state, {:peer_have, state.remote_peer_id, index})
    %{state | remote_bitfield: mark_have(state.remote_bitfield, index, state.piece_count)}
  end

  defp handle_wire_message({:bitfield, bits}, state) do
    bitfield =
      case state.piece_count && Flux.Torrent.Bitfield.from_wire(bits, state.piece_count) do
        {:ok, bf} -> bf
        _ -> bits
      end

    notify(state, {:peer_bitfield, state.remote_peer_id, bitfield})
    %{state | remote_bitfield: bitfield}
  end

  defp handle_wire_message({:request, index, begin, length}, state) do
    if state.am_choking or is_nil(state.storage_pid) do
      state
    else
      case Storage.read_block(state.storage_pid, index, begin, length) do
        {:ok, block} -> send_wire(state, {:piece, index, begin, block})
        _ -> :ok
      end

      state
    end
  end

  defp handle_wire_message({:piece, index, begin, block}, state) do
    notify(state, {:block_received, state.remote_peer_id, index, begin, block})
    state
  end

  defp handle_wire_message({:cancel, _index, _begin, _length}, state), do: state
  defp handle_wire_message({:port, _port}, state), do: state

  defp handle_wire_message({:extended, 0, payload}, state) do
    case WireProtocol.decode_extended_handshake(payload) do
      {:ok, %{extensions: extensions}} ->
        state = %{state | peer_extensions: extensions}

        if Map.has_key?(extensions, @ut_metadata_name) and is_nil(state.raw_info_bytes) do
          notify(state, {:peer_supports_ut_metadata, state.remote_peer_id})
        end

        state

      {:error, _reason} ->
        state
    end
  end

  defp handle_wire_message({:extended, ext_id, payload}, state) do
    case WireProtocol.decode_ut_metadata(payload) do
      {:ok, {:request, piece_index}} ->
        handle_ut_metadata_request(state, ext_id, piece_index)

      {:ok, {:data, piece_index, total_size, chunk}} ->
        notify(state, {:metadata_piece_received, state.remote_peer_id, piece_index, total_size, chunk})
        state

      {:ok, {:reject, _piece_index}} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp handle_ut_metadata_request(state, ext_id, piece_index) do
    if state.raw_info_bytes do
      payload = WireProtocol.encode_ut_metadata_data(ext_id, piece_index, state.raw_info_bytes)
      :gen_tcp.send(state.socket, payload)
    else
      :gen_tcp.send(state.socket, WireProtocol.encode_ut_metadata_reject(ext_id, piece_index))
    end

    state
  end

  # Mirrors the effect of a locally-initiated choke/interested state change
  # we just sent over the wire, so our own bookkeeping (e.g. whether we
  # honor incoming `request`s) stays in sync with what we told the peer.
  defp update_local_state(state, :choke), do: %{state | am_choking: true}
  defp update_local_state(state, :unchoke), do: %{state | am_choking: false}
  defp update_local_state(state, :interested), do: %{state | am_interested: true}
  defp update_local_state(state, :not_interested), do: %{state | am_interested: false}
  defp update_local_state(state, _message), do: state

  defp mark_have(nil, _index, _piece_count), do: nil
  defp mark_have(bf, index, _piece_count), do: Flux.Torrent.Bitfield.set(bf, index)

  defp send_wire(state, message) do
    :gen_tcp.send(state.socket, WireProtocol.encode_message(message))
  end

  defp notify(state, message), do: GenServer.cast(state.session_pid, message)
end
