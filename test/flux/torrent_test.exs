defmodule Flux.TorrentTest do
  use Flux.DataCase, async: false

  alias Flux.{Torrent, Downloads}
  alias Flux.Bencode
  alias Flux.Torrent.WireProtocol
  alias Flux.Torrent.Dht
  alias Flux.Torrent.Dht.Krpc

  @moduletag :tmp_dir

  # End-to-end: a real .torrent (single file, 2 pieces), a fake HTTP tracker
  # that points at a fake fully-seeded peer, and a real Flux.Torrent.Session
  # driving the whole download over real loopback TCP. Asserts the Download
  # row ends up :completed with the correct bytes actually on disk.

  defp start_fake_peer(info_hash, content, piece_length) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket, 15_000)
      {:ok, handshake_bin} = :gen_tcp.recv(socket, 68, 2000)
      {:ok, %{info_hash: ^info_hash}, ""} = WireProtocol.decode_handshake(handshake_bin)

      reply = WireProtocol.encode_handshake(info_hash, :crypto.hash(:sha, "fake-peer"))
      :ok = :gen_tcp.send(socket, reply)

      piece_count = ceil(byte_size(content) / piece_length)
      pad = rem(8 - rem(piece_count, 8), 8)
      all_ones = Bitwise.bsl(1, piece_count) - 1
      bits = <<all_ones::size(piece_count), 0::size(pad)>>

      :gen_tcp.send(socket, WireProtocol.encode_message({:bitfield, bits}))
      :gen_tcp.send(socket, WireProtocol.encode_message(:unchoke))

      serve_loop(socket, content, piece_length)
    end)

    port
  end

  defp serve_loop(socket, content, piece_length, buffer \\ <<>>) do
    case recv_message(socket, buffer) do
      {{:request, index, begin, length}, rest} ->
        block = binary_part(content, index * piece_length + begin, length)
        :gen_tcp.send(socket, WireProtocol.encode_message({:piece, index, begin, block}))
        serve_loop(socket, content, piece_length, rest)

      {:closed, _rest} ->
        :ok

      {_other, rest} ->
        serve_loop(socket, content, piece_length, rest)
    end
  end

  defp recv_message(socket, buffer) do
    case WireProtocol.decode_message(buffer) do
      {:ok, message, rest} ->
        {message, rest}

      {:incomplete, _} ->
        case :gen_tcp.recv(socket, 0, 5000) do
          {:ok, data} -> recv_message(socket, buffer <> data)
          {:error, _} -> {:closed, buffer}
        end
    end
  end

  defp start_fake_tracker(peer_port) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      accept_announce_loop(listen_socket, peer_port)
    end)

    port
  end

  defp accept_announce_loop(listen_socket, peer_port) do
    case :gen_tcp.accept(listen_socket, 20_000) do
      {:ok, socket} ->
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2000)

        peers_bin = <<127, 0, 0, 1, peer_port::16>>
        body = Bencode.encode([{"interval", 100_000}, {"peers", peers_bin}])

        response =
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        accept_announce_loop(listen_socket, peer_port)

      {:error, _} ->
        :ok
    end
  end

  test "a full download completes end-to-end via a real Session, fake tracker, and fake peer", %{
    tmp_dir: tmp_dir
  } do
    content = :binary.copy(<<1, 2, 3, 4>>, 8)
    piece_length = 16
    pieces = for <<chunk::binary-size(16) <- content>>, do: :crypto.hash(:sha, chunk)

    info_pairs = [
      {"length", byte_size(content)},
      {"name", "fixture.bin"},
      {"piece length", piece_length},
      {"pieces", Enum.join(pieces)}
    ]

    raw_info_bytes = Bencode.encode(info_pairs)
    info_hash = :crypto.hash(:sha, raw_info_bytes)

    peer_port = start_fake_peer(info_hash, content, piece_length)
    tracker_port = start_fake_tracker(peer_port)

    top_pairs = [
      {"announce", "http://127.0.0.1:#{tracker_port}/announce"},
      {"info", info_pairs}
    ]

    raw_torrent = Bencode.encode(top_pairs)

    assert {:ok, download_id} = Torrent.add_torrent_file(raw_torrent, tmp_dir)

    download = wait_until_completed(info_hash, 50)

    assert download.id == download_id
    assert download.state == :completed
    assert download.downloaded == byte_size(content)
    assert {:ok, on_disk} = File.read(Path.join(tmp_dir, "fixture.bin"))
    assert on_disk == content

    # The fake peer stays connected throughout (never closes its socket),
    # so live stats should still show it even after completion.
    assert %{peer_count: 1} = Torrent.stats(info_hash)

    Torrent.remove(info_hash, false)
  end

  test "falls back to the next tracker in the list when the first one is unreachable", %{
    tmp_dir: tmp_dir
  } do
    content = :binary.copy(<<5, 6, 7, 8>>, 8)
    piece_length = 16
    pieces = for <<chunk::binary-size(16) <- content>>, do: :crypto.hash(:sha, chunk)

    info_pairs = [
      {"length", byte_size(content)},
      {"name", "fallback.bin"},
      {"piece length", piece_length},
      {"pieces", Enum.join(pieces)}
    ]

    raw_info_bytes = Bencode.encode(info_pairs)
    info_hash = :crypto.hash(:sha, raw_info_bytes)

    peer_port = start_fake_peer(info_hash, content, piece_length)
    tracker_port = start_fake_tracker(peer_port)

    # An unsupported scheme fails synchronously in TrackerClient.dispatch/3
    # with zero network I/O — a deterministic "this tracker is broken" case
    # that doesn't depend on OS-level connection-refused/retry timing.
    top_pairs = [
      {"announce-list",
       [
         ["ftp://tracker.invalid/announce"],
         ["http://127.0.0.1:#{tracker_port}/announce"]
       ]},
      {"info", info_pairs}
    ]

    raw_torrent = Bencode.encode(top_pairs)

    assert {:ok, _download_id} = Torrent.add_torrent_file(raw_torrent, tmp_dir)

    download = wait_until_completed(info_hash, 100)
    assert download.state == :completed

    Torrent.remove(info_hash, false)
  end

  test "retries connecting to a peer that failed on the first attempt, without waiting for another announce",
       %{tmp_dir: tmp_dir} do
    content = :binary.copy(<<9, 10, 11, 12>>, 8)
    piece_length = 16
    pieces = for <<chunk::binary-size(16) <- content>>, do: :crypto.hash(:sha, chunk)

    info_pairs = [
      {"length", byte_size(content)},
      {"name", "retry.bin"},
      {"piece length", piece_length},
      {"pieces", Enum.join(pieces)}
    ]

    raw_info_bytes = Bencode.encode(info_pairs)
    info_hash = :crypto.hash(:sha, raw_info_bytes)

    # A "flaky" peer: the first connection is accepted then dropped
    # immediately with no handshake reply (simulating a failed first
    # attempt); the second connection (from the periodic peer-fill retry,
    # not a fresh announce — the tracker's announce interval here is
    # deliberately huge) behaves like a normal, fully-seeded peer.
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, peer_port} = :inet.port(listen_socket)

    spawn_link(fn ->
      {:ok, first} = :gen_tcp.accept(listen_socket, 5000)
      :gen_tcp.close(first)

      {:ok, socket} = :gen_tcp.accept(listen_socket, 15_000)
      {:ok, handshake_bin} = :gen_tcp.recv(socket, 68, 2000)
      {:ok, %{info_hash: ^info_hash}, ""} = WireProtocol.decode_handshake(handshake_bin)

      reply = WireProtocol.encode_handshake(info_hash, :crypto.hash(:sha, "flaky-peer"))
      :ok = :gen_tcp.send(socket, reply)

      piece_count = ceil(byte_size(content) / piece_length)
      pad = rem(8 - rem(piece_count, 8), 8)
      all_ones = Bitwise.bsl(1, piece_count) - 1
      bits = <<all_ones::size(piece_count), 0::size(pad)>>

      :gen_tcp.send(socket, WireProtocol.encode_message({:bitfield, bits}))
      :gen_tcp.send(socket, WireProtocol.encode_message(:unchoke))

      serve_loop(socket, content, piece_length)
    end)

    tracker_port = start_fake_tracker(peer_port)

    top_pairs = [
      {"announce", "http://127.0.0.1:#{tracker_port}/announce"},
      {"info", info_pairs}
    ]

    raw_torrent = Bencode.encode(top_pairs)

    assert {:ok, _download_id} = Torrent.add_torrent_file(raw_torrent, tmp_dir)

    download = wait_until_completed(info_hash, 100)
    assert download.state == :completed

    Torrent.remove(info_hash, false)
  end

  # Combines the metadata-exchange fake peer from peer_connection_test.exs
  # (BEP10 extended handshake + BEP9 ut_metadata piece serving) with the
  # plain data-serving fake peer above, on one connection — this is what a
  # magnet link with zero trackers actually needs on the other end: metadata
  # first, then the real download.
  defp start_fake_peer_with_metadata(info_hash, raw_info_bytes, content, piece_length) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket, 15_000)
      {:ok, handshake_bin} = :gen_tcp.recv(socket, 68, 2000)
      {:ok, %{info_hash: ^info_hash}, ""} = WireProtocol.decode_handshake(handshake_bin)

      reply = WireProtocol.encode_handshake(info_hash, :crypto.hash(:sha, "dht-fake-peer"))
      :ok = :gen_tcp.send(socket, reply)

      {{:extended, 0, _payload}, buffer} = recv_message(socket, <<>>)

      ext_handshake =
        WireProtocol.encode_extended_handshake(%{"ut_metadata" => 5}, byte_size(raw_info_bytes))

      :ok = :gen_tcp.send(socket, ext_handshake)

      {{:extended, 5, req_payload}, buffer} = recv_message(socket, buffer)
      {:ok, {:request, 0}} = WireProtocol.decode_ut_metadata(req_payload)
      :ok = :gen_tcp.send(socket, WireProtocol.encode_ut_metadata_data(5, 0, raw_info_bytes))

      piece_count = ceil(byte_size(content) / piece_length)
      pad = rem(8 - rem(piece_count, 8), 8)
      all_ones = Bitwise.bsl(1, piece_count) - 1
      bits = <<all_ones::size(piece_count), 0::size(pad)>>

      :gen_tcp.send(socket, WireProtocol.encode_message({:bitfield, bits}))
      :gen_tcp.send(socket, WireProtocol.encode_message(:unchoke))

      serve_loop(socket, content, piece_length, buffer)
    end)

    port
  end

  # Seeds the app's single, shared `Flux.Torrent.Dht` routing table with a
  # fake node the same way a real one would appear (any incoming query
  # registers the sender), then answers exactly one `get_peers` query for
  # `info_hash` with `peer_ip`/`peer_port`. The fake node's id is crafted to
  # have the minimum possible (non-zero) XOR distance to `info_hash` — this
  # guarantees it's the closest entry in the table (whatever else has
  # accumulated there from other tests sharing this app-wide singleton) and
  # so is queried in the very first round of the lookup.
  defp seed_dht_with_fake_node(info_hash, peer_ip, peer_port) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    <<prefix::binary-size(19), last_byte>> = info_hash
    fake_node_id = <<prefix::binary, Bitwise.bxor(last_byte, 1)>>

    ping = Krpc.encode_query("seed", "ping", [{"id", fake_node_id}])
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, Dht.port(), ping)
    {:ok, _reply} = :gen_udp.recv(socket, 0, 2000)

    spawn_link(fn ->
      {:ok, {ip, port, data}} = :gen_udp.recv(socket, 0, 15_000)
      {:ok, %{query: "get_peers", transaction_id: tid}} = Krpc.decode(data)
      {a, b, c, d} = peer_ip
      values = [<<a, b, c, d, peer_port::16>>]

      reply =
        Krpc.encode_response(tid, [{"id", fake_node_id}, {"token", "tok"}, {"values", values}])

      :gen_udp.send(socket, ip, port, reply)
    end)

    :ok
  end

  test "a magnet link with zero trackers still completes a download, found entirely via DHT", %{
    tmp_dir: tmp_dir
  } do
    content = :binary.copy(<<13, 14, 15, 16>>, 8)
    piece_length = 16
    pieces = for <<chunk::binary-size(16) <- content>>, do: :crypto.hash(:sha, chunk)

    info_pairs = [
      {"length", byte_size(content)},
      {"name", "dht-only.bin"},
      {"piece length", piece_length},
      {"pieces", Enum.join(pieces)}
    ]

    raw_info_bytes = Bencode.encode(info_pairs)
    info_hash = :crypto.hash(:sha, raw_info_bytes)

    peer_port = start_fake_peer_with_metadata(info_hash, raw_info_bytes, content, piece_length)
    :ok = seed_dht_with_fake_node(info_hash, {127, 0, 0, 1}, peer_port)

    magnet_uri = "magnet:?xt=urn:btih:" <> Base.encode16(info_hash, case: :lower)
    assert {:ok, _download_id} = Torrent.add_magnet(magnet_uri, tmp_dir)

    download = wait_until_completed(info_hash, 150)
    assert download.state == :completed
    assert {:ok, on_disk} = File.read(Path.join(tmp_dir, "dht-only.bin"))
    assert on_disk == content

    Torrent.remove(info_hash, false)
  end

  test "stats/1 returns zeroed-out stats when no session is running for that info_hash" do
    info_hash = :crypto.hash(:sha, "no-such-session-#{System.unique_integer()}")

    assert Torrent.stats(info_hash) == %{
             peer_count: 0,
             connecting_count: 0,
             tracker_seeders: nil,
             tracker_leechers: nil
           }
  end

  defp wait_until_completed(_info_hash, 0), do: flunk("download did not complete in time")

  defp wait_until_completed(info_hash, attempts_left) do
    case Downloads.get_download_by_info_hash(info_hash) do
      %{state: :completed} = download ->
        download

      _other ->
        Process.sleep(200)
        wait_until_completed(info_hash, attempts_left - 1)
    end
  end
end
