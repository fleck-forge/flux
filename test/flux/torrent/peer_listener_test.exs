defmodule Flux.Torrent.PeerListenerTest do
  use ExUnit.Case, async: false

  alias Flux.Torrent.{PeerListener, WireProtocol}

  @info_hash :crypto.hash(:sha, "listener-test")
  @our_peer_id :crypto.hash(:sha, "listener-us")
  @remote_peer_id :crypto.hash(:sha, "listener-them")

  # A fake Session.Worker: just enough to answer :connection_info and
  # receive the resulting {:peer_connected, ...} cast so we can assert on it.
  defp start_fake_session(info_hash) do
    # A small proxy GenServer stands in for the real Session.Worker: it
    # registers itself in the registry (Registry.register/3 must be called
    # by the process being registered) and answers :connection_info.
    {:ok, session_pid} =
      GenServer.start_link(Flux.Torrent.PeerListenerTest.FakeSession, {info_hash, self()})

    session_pid
  end

  # Flux.Torrent.Registry and Flux.Torrent.PeerListener are permanent,
  # app-wide singletons started by Flux.Application (configured to bind
  # to a random port in the test environment) — reuse them rather than
  # starting a conflicting second instance under the same name.
  setup do
    %{port: PeerListener.port()}
  end

  test "routes a handshake for a known info_hash to a new PeerConnection", %{port: port} do
    _session = start_fake_session(@info_hash)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    handshake = WireProtocol.encode_handshake(@info_hash, @remote_peer_id)
    :ok = :gen_tcp.send(socket, handshake)

    {:ok, reply} = :gen_tcp.recv(socket, 68, 2000)

    assert {:ok, %{info_hash: @info_hash, peer_id: @our_peer_id}, ""} =
             WireProtocol.decode_handshake(reply)

    assert_receive {:"$gen_cast", {:peer_connected, _pid, @remote_peer_id}}, 2000
  end

  test "closes the socket for an unknown info_hash", %{port: port} do
    unknown_hash = :crypto.hash(:sha, "nobody-has-this")

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    handshake = WireProtocol.encode_handshake(unknown_hash, @remote_peer_id)
    :ok = :gen_tcp.send(socket, handshake)

    assert {:error, :closed} = :gen_tcp.recv(socket, 68, 2000)
  end
end

defmodule Flux.Torrent.PeerListenerTest.FakeSession do
  use GenServer

  def init({info_hash, parent}) do
    {:ok, _owner} = Registry.register(Flux.Torrent.Registry, info_hash, nil)

    {:ok,
     %{
       our_peer_id: :crypto.hash(:sha, "listener-us"),
       info_hash: info_hash,
       session_pid: parent,
       storage_pid: nil,
       piece_count: nil,
       our_bitfield: nil,
       raw_info_bytes: nil,
       metadata_size: nil
     }}
  end

  def handle_call(:connection_info, _from, state) do
    opts = [
      session_pid: state.session_pid,
      info_hash: state.info_hash,
      our_peer_id: state.our_peer_id,
      storage_pid: state.storage_pid,
      piece_count: state.piece_count,
      our_bitfield: state.our_bitfield,
      raw_info_bytes: state.raw_info_bytes,
      metadata_size: state.metadata_size
    ]

    {:reply, opts, state}
  end
end
