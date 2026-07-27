defmodule Flux.Torrent.Utp.Socket do
  @moduledoc """
  One GenServer per outbound BEP 29 (uTP) connection — mirrors
  `Flux.Torrent.PeerConnection`'s one-process-per-TCP-connection model, but
  for uTP. Owns no socket itself (all I/O goes through the shared
  `Flux.Torrent.Utp.Manager`); delivers received bytes to its owner via
  `{:utp_data, pid, binary}`, mirroring `:gen_tcp`'s `{:tcp, socket, data}`
  shape so `PeerConnection` needs minimal transport-specific branching.

  v1 simplifications (deliberate, matching this project's existing
  "simple is fine" precedent — see `PiecePicker`/`Choker`/`Dht`):
  a small **fixed** send window (not LEDBAT congestion control), a single
  **fixed/backoff retransmit timer** per unacked packet (no measured RTT),
  and **no selective ACK** — an out-of-order incoming data packet is
  dropped (not buffered/reordered) and recovered purely by the sender's own
  timeout-retransmit. This still interoperates correctly with a real uTP
  peer; it's just less aggressive about throughput than libutp.
  """

  use GenServer
  require Logger

  alias Flux.Torrent.Utp.{Packet, Manager}

  @chunk_size 1024
  @max_window 8
  @base_rto 1000
  @max_rto 8000
  @max_retries 5

  defstruct [
    :remote,
    :conn_id_recv,
    :conn_id_send,
    :owner,
    :manager,
    status: :connecting,
    seq_nr: 1,
    ack_nr: 0,
    send_window: %{},
    pending_chunks: [],
    handshake_seq: nil
  ]

  ## Client API

  def start_link(opts), do: GenServer.start(__MODULE__, opts)

  @doc "Sends `data`, chunked and windowed internally; returns once accepted (not once acked), like :gen_tcp.send/2."
  def send_data(pid, data), do: GenServer.call(pid, {:send_data, data})

  @doc "Initiates a graceful close (sends ST_FIN); does not block for the remote's ack."
  def close(pid), do: GenServer.cast(pid, :close)

  ## Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      remote: Keyword.fetch!(opts, :remote),
      conn_id_recv: Keyword.fetch!(opts, :conn_id_recv),
      conn_id_send: Keyword.fetch!(opts, :conn_id_recv) + 1,
      owner: Keyword.fetch!(opts, :owner),
      manager: Keyword.get(opts, :manager, Manager)
    }

    {:ok, state, {:continue, :send_syn}}
  end

  @impl true
  def handle_continue(:send_syn, state) do
    seq = state.seq_nr

    packet = %{
      type: :st_syn,
      connection_id: state.conn_id_recv,
      timestamp_us: now_us(),
      timestamp_diff_us: 0,
      wnd_size: @max_window * @chunk_size,
      seq_nr: seq,
      ack_nr: 0,
      payload: <<>>
    }

    send_packet(state, packet)
    timer = schedule_retransmit(seq, @base_rto)

    {:noreply,
     %{
       state
       | seq_nr: seq + 1,
         handshake_seq: seq,
         send_window: Map.put(state.send_window, seq, {packet, timer, 0})
     }}
  end

  @impl true
  def handle_call({:send_data, data}, _from, %{status: :connected} = state) do
    chunks = chunk(data)
    {:reply, :ok, flush_window(%{state | pending_chunks: state.pending_chunks ++ chunks})}
  end

  def handle_call({:send_data, _data}, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  @impl true
  def handle_cast(:close, state) do
    seq = state.seq_nr

    packet = %{
      type: :st_fin,
      connection_id: state.conn_id_send,
      timestamp_us: now_us(),
      timestamp_diff_us: 0,
      wnd_size: 0,
      seq_nr: seq,
      ack_nr: state.ack_nr,
      payload: <<>>
    }

    send_packet(state, packet)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:utp_incoming, packet}, state) do
    handle_packet(state, packet)
  end

  def handle_info({:retransmit, seq}, state) do
    case Map.get(state.send_window, seq) do
      nil ->
        {:noreply, state}

      {_packet, _timer, retries} when retries >= @max_retries ->
        fail_connection(state, :timeout)

      {packet, _old_timer, retries} ->
        send_packet(state, %{packet | timestamp_us: now_us()})
        rto = min(@base_rto * Integer.pow(2, retries + 1), @max_rto)
        timer = schedule_retransmit(seq, rto)

        {:noreply,
         %{state | send_window: Map.put(state.send_window, seq, {packet, timer, retries + 1})}}
    end
  end

  defp handle_packet(%{status: :connecting} = state, %{type: :st_state} = packet) do
    state = ack_send_window(state, packet.ack_nr)

    if Map.has_key?(state.send_window, state.handshake_seq) do
      # Still (re)transmitting the SYN elsewhere; a stray/duplicate STATE
      # for a different ack shouldn't flip us to connected.
      {:noreply, state}
    else
      send(state.owner, {:utp_connected, self()})
      {:noreply, %{state | status: :connected, ack_nr: packet.seq_nr}}
    end
  end

  defp handle_packet(%{status: :connecting} = state, %{type: :st_reset}) do
    fail_connection(state, :reset)
  end

  defp handle_packet(%{status: :connecting} = state, _other_packet), do: {:noreply, state}

  defp handle_packet(%{status: :connected} = state, %{type: :st_state} = packet) do
    {:noreply, flush_window(ack_send_window(state, packet.ack_nr))}
  end

  defp handle_packet(%{status: :connected} = state, %{type: :st_data} = packet) do
    state = ack_send_window(state, packet.ack_nr)

    state =
      if packet.seq_nr == state.ack_nr + 1 do
        send(state.owner, {:utp_data, self(), packet.payload})
        %{state | ack_nr: packet.seq_nr}
      else
        state
      end

    send_ack(state)
    {:noreply, flush_window(state)}
  end

  defp handle_packet(%{status: :connected} = state, %{type: :st_fin} = packet) do
    state = ack_send_window(state, packet.ack_nr)

    if packet.seq_nr == state.ack_nr + 1 do
      state = %{state | ack_nr: packet.seq_nr}
      send_ack(state)
      send(state.owner, {:utp_closed, self(), :remote_fin})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp handle_packet(state, %{type: :st_reset}) do
    send(state.owner, {:utp_closed, self(), :reset})
    {:stop, :normal, state}
  end

  defp handle_packet(state, _other_packet), do: {:noreply, state}

  defp fail_connection(state, reason) do
    msg =
      if state.status == :connecting,
        do: {:utp_connect_failed, self(), reason},
        else: {:utp_closed, self(), reason}

    send(state.owner, msg)
    {:stop, :normal, state}
  end

  ## Send-window / chunking internals

  # A plain bitstring comprehension (`for <<c::binary-size(n) <- data>>`)
  # silently drops any trailing remainder shorter than `n` — wrong here,
  # since most real writes aren't an exact multiple of @chunk_size.
  defp chunk(<<>>), do: []

  defp chunk(data) when byte_size(data) <= @chunk_size, do: [data]

  defp chunk(<<chunk::binary-size(@chunk_size), rest::binary>>), do: [chunk | chunk(rest)]

  defp flush_window(state) do
    slots_free = @max_window - map_size(state.send_window)

    if slots_free > 0 and state.pending_chunks != [] do
      {to_send, rest} = Enum.split(state.pending_chunks, slots_free)
      state = Enum.reduce(to_send, state, &send_data_chunk(&2, &1))
      %{state | pending_chunks: rest}
    else
      state
    end
  end

  defp send_data_chunk(state, chunk) do
    seq = state.seq_nr

    packet = %{
      type: :st_data,
      connection_id: state.conn_id_send,
      timestamp_us: now_us(),
      timestamp_diff_us: 0,
      wnd_size: @max_window * @chunk_size,
      seq_nr: seq,
      ack_nr: state.ack_nr,
      payload: chunk
    }

    send_packet(state, packet)
    timer = schedule_retransmit(seq, @base_rto)
    %{state | seq_nr: seq + 1, send_window: Map.put(state.send_window, seq, {packet, timer, 0})}
  end

  defp ack_send_window(state, ack_nr) do
    {kept, removed} = Enum.split_with(state.send_window, fn {seq, _} -> seq > ack_nr end)
    for {_seq, {_packet, timer, _retries}} <- removed, do: Process.cancel_timer(timer)
    %{state | send_window: Map.new(kept)}
  end

  defp send_ack(state) do
    packet = %{
      type: :st_state,
      connection_id: state.conn_id_send,
      timestamp_us: now_us(),
      timestamp_diff_us: 0,
      wnd_size: @max_window * @chunk_size,
      seq_nr: state.seq_nr,
      ack_nr: state.ack_nr,
      payload: <<>>
    }

    send_packet(state, packet)
  end

  defp send_packet(state, packet) do
    {ip, port} = state.remote
    Manager.send_packet({ip, port}, Packet.encode(packet))
  end

  defp schedule_retransmit(seq, rto), do: Process.send_after(self(), {:retransmit, seq}, rto)

  defp now_us, do: System.monotonic_time(:microsecond)
end
