defmodule Flux.Torrent.Utp.SocketTest do
  # Flux.Torrent.Utp.Manager is a single app-wide singleton (like
  # Flux.Torrent.Dht) — async:false avoids this file's connections
  # interfering with each other's fake-peer sockets/timing.
  use ExUnit.Case, async: false

  alias Flux.Torrent.Utp.{Manager, Packet}

  defp open_fake_peer do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    socket
  end

  defp recv_packet(socket, timeout \\ 2000) do
    {:ok, {ip, port, data}} = :gen_udp.recv(socket, 0, timeout)
    {:ok, packet} = Packet.decode(data)
    {packet, ip, port}
  end

  defp send_packet(socket, ip, port, packet),
    do: :gen_udp.send(socket, ip, port, Packet.encode(packet))

  # Replies to the SYN with the ST_STATE half of the handshake, using the
  # exact connection-id/seq-nr relationship BEP 29 defines: the SYN's
  # connection_id (X) is what the *initiator* listens on, so every packet
  # *we* (the fake peer) send back must also carry X — X+1 is what the
  # initiator will address packets *to us* with instead.
  defp fake_peer_handshake(socket) do
    {syn, ip, port} = recv_packet(socket)
    assert syn.type == :st_syn

    state_packet = %{
      type: :st_state,
      connection_id: syn.connection_id,
      timestamp_us: 0,
      timestamp_diff_us: 0,
      wnd_size: 1_048_576,
      seq_nr: 100,
      ack_nr: syn.seq_nr,
      payload: <<>>
    }

    send_packet(socket, ip, port, state_packet)
    {ip, port, syn.connection_id, syn.connection_id + 1}
  end

  test "connect/3 performs a SYN/STATE handshake with a fake uTP peer" do
    fake_peer = open_fake_peer()
    {:ok, fake_port} = :inet.port(fake_peer)

    task = Task.async(fn -> fake_peer_handshake(fake_peer) end)

    assert {:ok, pid} = Manager.connect({127, 0, 0, 1}, fake_port, 2000)
    assert is_pid(pid)

    Task.await(task)
    :gen_udp.close(fake_peer)
  end

  test "connect/3 returns an error when nobody answers the SYN" do
    {:ok, dead_socket} = :gen_udp.open(0, [:binary])
    {:ok, dead_port} = :inet.port(dead_socket)
    :ok = :gen_udp.close(dead_socket)

    assert {:error, _reason} = Manager.connect({127, 0, 0, 1}, dead_port, 500)
  end

  test "send_data/2 delivers a chunk to the peer, and incoming data reaches the owner" do
    fake_peer = open_fake_peer()
    {:ok, fake_port} = :inet.port(fake_peer)

    task = Task.async(fn -> fake_peer_handshake(fake_peer) end)
    assert {:ok, pid} = Manager.connect({127, 0, 0, 1}, fake_port, 2000)
    {peer_ip, peer_port, our_conn_id, _their_conn_id} = Task.await(task)

    assert :ok = Flux.Torrent.Utp.Socket.send_data(pid, "hello utp")

    {data_packet, ^peer_ip, ^peer_port} = recv_packet(fake_peer)
    assert data_packet.type == :st_data
    assert data_packet.payload == "hello utp"

    ack = %{
      type: :st_state,
      connection_id: our_conn_id,
      timestamp_us: 0,
      timestamp_diff_us: 0,
      wnd_size: 1_048_576,
      seq_nr: 101,
      ack_nr: data_packet.seq_nr,
      payload: <<>>
    }

    send_packet(fake_peer, peer_ip, peer_port, ack)

    incoming = %{
      type: :st_data,
      connection_id: our_conn_id,
      timestamp_us: 0,
      timestamp_diff_us: 0,
      wnd_size: 1_048_576,
      seq_nr: 101,
      ack_nr: data_packet.seq_nr,
      payload: "world"
    }

    send_packet(fake_peer, peer_ip, peer_port, incoming)
    assert_receive {:utp_data, ^pid, "world"}, 2000

    :gen_udp.close(fake_peer)
  end

  test "a dropped data packet is recovered via timeout-retransmit, without any selective ACK" do
    fake_peer = open_fake_peer()
    {:ok, fake_port} = :inet.port(fake_peer)

    task = Task.async(fn -> fake_peer_handshake(fake_peer) end)
    assert {:ok, pid} = Manager.connect({127, 0, 0, 1}, fake_port, 2000)
    {peer_ip, peer_port, _our_conn_id, _their_conn_id} = Task.await(task)

    assert :ok = Flux.Torrent.Utp.Socket.send_data(pid, "first attempt is dropped")

    # Silently drop the first delivery (never ack it) — the fake peer just
    # doesn't respond, exactly like a lost UDP datagram in the real world.
    {first_attempt, _ip, _port} = recv_packet(fake_peer)
    assert first_attempt.type == :st_data

    # The retransmit fires on a fixed ~1s timer; wait past it for the
    # resend, then actually ack it this time.
    {retransmitted, ^peer_ip, ^peer_port} = recv_packet(fake_peer, 3000)
    assert retransmitted.type == :st_data
    assert retransmitted.seq_nr == first_attempt.seq_nr
    assert retransmitted.payload == first_attempt.payload

    :gen_udp.close(fake_peer)
  end
end
