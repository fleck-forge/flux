defmodule Flux.TorrentTest do
  use Flux.DataCase, async: false

  alias Flux.{Torrent, Downloads}
  alias Flux.Bencode
  alias Flux.Torrent.WireProtocol

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
      {:ok, socket} = :gen_tcp.accept(listen_socket, 5000)
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
    case :gen_tcp.accept(listen_socket, 5000) do
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

    Torrent.remove(info_hash, false)
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
