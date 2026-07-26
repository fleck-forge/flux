defmodule Flux.Torrent.TrackerClient.UdpTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.TrackerClient.Udp

  @protocol_magic 0x41727101980

  # A fake BEP 15 UDP tracker: answers exactly one connect + one announce
  # round trip on loopback, then exits.
  defp start_fake_tracker(connection_id, announce_reply_fields) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    parent = self()

    spawn_link(fn ->
      {:ok, {client_ip, client_port, connect_req}} = :gen_udp.recv(socket, 0, 5000)
      <<@protocol_magic::64, 0::32, txn_id::32>> = connect_req

      connect_resp = <<0::32, txn_id::32, connection_id::64>>
      :ok = :gen_udp.send(socket, client_ip, client_port, connect_resp)

      {:ok, {^client_ip, ^client_port, announce_req}} = :gen_udp.recv(socket, 0, 5000)

      <<^connection_id::64, 1::32, announce_txn_id::32, info_hash::binary-size(20),
        peer_id::binary-size(20), downloaded::64, left::64, uploaded::64, event::32,
        _ip::32, _key::32, _numwant::32-signed, port::16>> = announce_req

      send(
        parent,
        {:announce_received,
         %{
           info_hash: info_hash,
           peer_id: peer_id,
           downloaded: downloaded,
           left: left,
           uploaded: uploaded,
           event: event,
           port: port
         }}
      )

      %{interval: interval, leechers: leechers, seeders: seeders, peers: peers_bin} =
        announce_reply_fields

      announce_resp =
        <<1::32, announce_txn_id::32, interval::32, leechers::32, seeders::32, peers_bin::binary>>

      :gen_udp.send(socket, client_ip, client_port, announce_resp)
      :gen_udp.close(socket)
    end)

    port
  end

  defp base_params do
    %{
      info_hash: :crypto.hash(:sha, "info"),
      peer_id: :crypto.hash(:sha, "peer"),
      port: 6881,
      uploaded: 111,
      downloaded: 222,
      left: 333
    }
  end

  test "announce/3 performs connect then announce and parses the response" do
    peers_bin = <<127, 0, 0, 1, 6881::16>>

    port =
      start_fake_tracker(0xDEADBEEF, %{interval: 1800, leechers: 3, seeders: 7, peers: peers_bin})

    assert {:ok, result} = Udp.announce("udp://127.0.0.1:#{port}", base_params())
    assert result.interval == 1800
    assert result.leechers == 3
    assert result.seeders == 7
    assert result.peers == [{{127, 0, 0, 1}, 6881}]

    assert_receive {:announce_received, received}, 1000
    assert received.info_hash == base_params().info_hash
    assert received.peer_id == base_params().peer_id
    assert received.downloaded == 222
    assert received.left == 333
    assert received.uploaded == 111
    assert received.port == 6881
    # no event -> code 0
    assert received.event == 0
  end

  test "announce/3 encodes the started event correctly" do
    port = start_fake_tracker(1, %{interval: 1800, leechers: 0, seeders: 0, peers: <<>>})

    assert {:ok, _} = Udp.announce("udp://127.0.0.1:#{port}", Map.put(base_params(), :event, :started))
    assert_receive {:announce_received, %{event: 2}}, 1000
  end
end
