defmodule Flux.Torrent.PeerConnectionTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.{PeerConnection, WireProtocol, Storage, MetaInfo}

  @info_hash :crypto.hash(:sha, "test-torrent")
  @our_peer_id :crypto.hash(:sha, "us")
  @remote_peer_id :crypto.hash(:sha, "them")

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  defp accept_and_handshake(listen_socket, opts \\ []) do
    {:ok, socket} = :gen_tcp.accept(listen_socket, 2000)
    {:ok, handshake_bin} = :gen_tcp.recv(socket, 68, 2000)
    {:ok, decoded, ""} = WireProtocol.decode_handshake(handshake_bin)

    remote_info_hash = Keyword.get(opts, :info_hash, @info_hash)
    reply = WireProtocol.encode_handshake(remote_info_hash, @remote_peer_id)
    :ok = :gen_tcp.send(socket, reply)

    {socket, decoded}
  end

  # Reads exactly one wire message from `socket`, accumulating bytes across
  # multiple TCP reads if needed (a message can arrive split across reads,
  # or bundled with the next one in a single read).
  defp recv_message(socket, buffer \\ <<>>) do
    case WireProtocol.decode_message(buffer) do
      {:ok, message, rest} ->
        {message, rest}

      {:incomplete, _} ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
        recv_message(socket, buffer <> data)
    end
  end

  defp start_outbound(port, opts) do
    default_opts = [
      session_pid: self(),
      info_hash: @info_hash,
      our_peer_id: @our_peer_id,
      piece_count: nil,
      our_bitfield: nil,
      storage_pid: nil
    ]

    PeerConnection.start_link_outbound({127, 0, 0, 1}, port, Keyword.merge(default_opts, opts))
  end

  test "successful handshake notifies the session with the remote peer_id" do
    {listen_socket, port} = listen()

    task = Task.async(fn -> accept_and_handshake(listen_socket) end)
    assert {:ok, _pid} = start_outbound(port, [])
    {_socket, decoded} = Task.await(task)

    assert decoded.info_hash == @info_hash
    assert_receive {:"$gen_cast", {:peer_connected, _pid, @remote_peer_id}}, 1000
  end

  test "rejects a peer whose handshake info_hash doesn't match" do
    {listen_socket, port} = listen()
    wrong_hash = :crypto.hash(:sha, "wrong")

    task = Task.async(fn -> accept_and_handshake(listen_socket, info_hash: wrong_hash) end)

    Process.flag(:trap_exit, true)
    result = start_outbound(port, [])
    Task.await(task)

    assert {:error, :info_hash_mismatch} = result
  end

  test "exchanges bitfields after handshake" do
    {listen_socket, port} = listen()

    task =
      Task.async(fn ->
        {socket, _} = accept_and_handshake(listen_socket)
        # Drain the extended handshake the peer connection sends.
        {{:extended, 0, _}, _rest} = recv_message(socket)
        :gen_tcp.send(socket, WireProtocol.encode_message({:bitfield, <<0b10100000>>}))
        socket
      end)

    {:ok, _pid} = start_outbound(port, piece_count: 3)
    Task.await(task)

    assert_receive {:"$gen_cast", {:peer_bitfield, @remote_peer_id, bitfield}}, 1000
    assert Flux.Torrent.Bitfield.has?(bitfield, 0)
    refute Flux.Torrent.Bitfield.has?(bitfield, 1)
    assert Flux.Torrent.Bitfield.has?(bitfield, 2)
  end

  test "serves a requested block once unchoked, via Storage" do
    tmp_dir = System.tmp_dir!() |> Path.join("flux_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    data = :binary.copy(<<1, 2, 3, 4>>, 4)

    meta = %MetaInfo{
      info_hash: @info_hash,
      raw_info_bytes: "x",
      name: "test",
      piece_length: 16,
      pieces: [:crypto.hash(:sha, data)],
      files: [%{path: ["file.bin"], length: 16}],
      total_length: 16,
      trackers: [],
      private?: false
    }

    {:ok, storage_pid} = Storage.start_link(meta_info: meta, save_path: tmp_dir)
    :ok = Storage.write_block(storage_pid, 0, 0, data)

    {listen_socket, port} = listen()

    task =
      Task.async(fn ->
        {socket, _} = accept_and_handshake(listen_socket)
        {{:extended, 0, _}, buffer} = recv_message(socket)
        {:unchoke, buffer} = recv_message(socket, buffer)
        :gen_tcp.send(socket, WireProtocol.encode_message({:request, 0, 0, 16}))
        {{:piece, 0, 0, block}, _rest} = recv_message(socket, buffer)
        block
      end)

    {:ok, pid} = start_outbound(port, storage_pid: storage_pid, piece_count: 1)
    PeerConnection.send_message(pid, :unchoke)

    assert Task.await(task) == data
  end

  test "BEP10/BEP9: peer advertising ut_metadata triggers a notification, and serves requested pieces" do
    raw_info_bytes = :crypto.strong_rand_bytes(100)

    {listen_socket, port} = listen()

    task =
      Task.async(fn ->
        {socket, _} = accept_and_handshake(listen_socket)
        {{:extended, 0, payload}, buffer} = recv_message(socket)

        {:ok, %{extensions: %{"ut_metadata" => _}}} =
          WireProtocol.decode_extended_handshake(payload)

        # Advertise our own ut_metadata extension id (5) back.
        handshake =
          WireProtocol.encode_extended_handshake(%{"ut_metadata" => 5}, byte_size(raw_info_bytes))

        :gen_tcp.send(socket, handshake)

        # Expect a metadata piece request addressed to ext_id 5.
        {{:extended, 5, req_payload}, buffer} = recv_message(socket, buffer)
        {:ok, {:request, 0}} = WireProtocol.decode_ut_metadata(req_payload)

        data_msg = WireProtocol.encode_ut_metadata_data(5, 0, raw_info_bytes)
        :gen_tcp.send(socket, data_msg)
        _ = buffer
        :ok
      end)

    {:ok, pid} = start_outbound(port, [])
    assert_receive {:"$gen_cast", {:peer_supports_ut_metadata, @remote_peer_id}}, 1000

    PeerConnection.request_metadata_piece(pid, 0)

    assert_receive {:"$gen_cast",
                    {:metadata_piece_received, @remote_peer_id, 0, total_size, chunk}},
                   1000

    assert total_size == byte_size(raw_info_bytes)
    assert chunk == raw_info_bytes

    Task.await(task)
  end
end
