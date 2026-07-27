defmodule Flux.Torrent.DhtTest do
  # Flux.Torrent.Dht is a single app-wide singleton with shared mutable
  # state (the routing table) — async:false avoids this file's own tests
  # interfering with each other's routing-table contents/timing.
  use ExUnit.Case, async: false

  alias Flux.Torrent.Dht
  alias Flux.Torrent.Dht.Krpc

  @our_test_id :crypto.hash(:sha, "fake-remote-node")

  setup do
    {:ok, port} = {:ok, Dht.port()}
    %{dht_port: port}
  end

  defp open_fake_node do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    socket
  end

  defp recv_krpc(socket, timeout \\ 2000) do
    {:ok, {ip, port, data}} = :gen_udp.recv(socket, 0, timeout)
    {:ok, msg} = Krpc.decode(data)
    {msg, ip, port}
  end

  test "responds to ping", %{dht_port: dht_port} do
    socket = open_fake_node()
    packet = Krpc.encode_query("t1", "ping", [{"id", @our_test_id}])
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, packet)

    {msg, _ip, _port} = recv_krpc(socket)
    assert msg.type == :response
    assert msg.transaction_id == "t1"
    assert is_binary(msg.id)
    assert byte_size(msg.id) == 20

    :gen_udp.close(socket)
  end

  test "responds to find_node with a well-formed (possibly empty) node list", %{
    dht_port: dht_port
  } do
    socket = open_fake_node()
    target = :crypto.hash(:sha, "some-target")
    packet = Krpc.encode_query("t2", "find_node", [{"id", @our_test_id}, {"target", target}])
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, packet)

    {msg, _ip, _port} = recv_krpc(socket)
    assert msg.type == :response
    assert is_list(msg.nodes)

    :gen_udp.close(socket)
  end

  test "responds to get_peers with a token and nodes (v1 never returns values for others' torrents)",
       %{
         dht_port: dht_port
       } do
    socket = open_fake_node()
    info_hash = :crypto.hash(:sha, "some-torrent")

    packet =
      Krpc.encode_query("t3", "get_peers", [{"id", @our_test_id}, {"info_hash", info_hash}])

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, packet)

    {msg, _ip, _port} = recv_krpc(socket)
    assert msg.type == :response
    assert is_binary(msg.token)
    assert msg.values == []

    :gen_udp.close(socket)
  end

  test "accepts announce_peer with a valid token (obtained from get_peers) and rejects a bad one",
       %{
         dht_port: dht_port
       } do
    socket = open_fake_node()
    info_hash = :crypto.hash(:sha, "announce-torrent")

    gp_packet =
      Krpc.encode_query("t4", "get_peers", [{"id", @our_test_id}, {"info_hash", info_hash}])

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, gp_packet)
    {%{token: token}, _ip, _port} = recv_krpc(socket)

    good_packet =
      Krpc.encode_query("t5", "announce_peer", [
        {"id", @our_test_id},
        {"info_hash", info_hash},
        {"port", 6881},
        {"token", token}
      ])

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, good_packet)
    {good_reply, _ip, _port} = recv_krpc(socket)
    assert good_reply.type == :response

    bad_packet =
      Krpc.encode_query("t6", "announce_peer", [
        {"id", @our_test_id},
        {"info_hash", info_hash},
        {"port", 6881},
        {"token", "not-the-real-token"}
      ])

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, dht_port, bad_packet)
    {bad_reply, _ip, _port} = recv_krpc(socket)
    assert bad_reply.type == :error
    assert bad_reply.code == 203

    :gen_udp.close(socket)
  end

  test "query_and_wait/4 round-trips against a fake remote node", %{dht_port: dht_port} do
    fake_node_socket = open_fake_node()
    {:ok, fake_port} = :inet.port(fake_node_socket)

    responder =
      spawn_link(fn ->
        {:ok, {ip, port, data}} = :gen_udp.recv(fake_node_socket, 0, 2000)
        {:ok, %{query: "ping", transaction_id: tid}} = Krpc.decode(data)
        reply = Krpc.encode_response(tid, [{"id", @our_test_id}])
        :gen_udp.send(fake_node_socket, ip, port, reply)
      end)

    assert {:ok, %{type: :response, id: @our_test_id}} =
             Dht.query_and_wait({{127, 0, 0, 1}, fake_port}, "ping", [], 2000)

    Process.exit(responder, :kill)
    :gen_udp.close(fake_node_socket)
    _ = dht_port
  end

  test "query_and_wait/4 times out when nobody answers" do
    {:ok, dead_socket} = :gen_udp.open(0, [:binary])
    {:ok, dead_port} = :inet.port(dead_socket)
    :ok = :gen_udp.close(dead_socket)

    assert {:error, :timeout} = Dht.query_and_wait({{127, 0, 0, 1}, dead_port}, "ping", [], 300)
  end

  test "get_peers/2 discovers peers via a fake node already in the routing table" do
    fake_node_socket = open_fake_node()
    info_hash = :crypto.hash(:sha, "lookup-target-#{System.unique_integer()}")
    real_peer = {{203, 0, 113, 5}, 51413}

    # This `Dht` GenServer is a single app-wide singleton, and if the test
    # environment has real internet access, its routing table may already
    # hold real mainline DHT nodes from a genuine bootstrap — not just this
    # file's other fake ones. Craft the fake node's id to have the minimum
    # possible (non-zero) XOR distance to `info_hash`, guaranteeing it's the
    # closest entry in the table no matter what else has accumulated there,
    # so the lookup queries it in the very first round regardless.
    <<prefix::binary-size(19), last_byte>> = info_hash
    fake_node_id = <<prefix::binary, Bitwise.bxor(last_byte, 1)>>

    # Seed our routing table with this fake node the same way a real one
    # would appear: it queries us first (any incoming query registers the
    # sender via `maybe_add_node`).
    ping = Krpc.encode_query("seed", "ping", [{"id", fake_node_id}])
    :ok = :gen_udp.send(fake_node_socket, {127, 0, 0, 1}, Dht.port(), ping)
    {:ok, _reply} = :gen_udp.recv(fake_node_socket, 0, 2000)

    responder =
      spawn_link(fn ->
        {:ok, {ip, port, data}} = :gen_udp.recv(fake_node_socket, 0, 3000)
        {:ok, %{query: "get_peers", transaction_id: tid}} = Krpc.decode(data)
        {peer_ip, peer_port} = real_peer
        {a, b, c, d} = peer_ip
        values = [<<a, b, c, d, peer_port::16>>]

        reply =
          Krpc.encode_response(tid, [{"id", fake_node_id}, {"token", "tok"}, {"values", values}])

        :gen_udp.send(fake_node_socket, ip, port, reply)
      end)

    assert {:ok, peers} = Dht.get_peers(info_hash, max_rounds: 2, per_query_timeout: 2000)
    assert real_peer in peers

    Process.exit(responder, :kill)
    :gen_udp.close(fake_node_socket)
  end
end
