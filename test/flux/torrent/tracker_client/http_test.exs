defmodule Flux.Torrent.TrackerClient.HttpTest do
  use ExUnit.Case, async: true

  alias Flux.Bencode
  alias Flux.Torrent.TrackerClient.Http

  # A minimal raw-socket fake HTTP tracker: accepts one connection, ignores
  # the request, replies with a fixed bencoded body. Avoids pulling in a
  # full Plug/Bandit fixture for what's ultimately "respond with these
  # exact bytes."
  defp start_fake_tracker(response_body) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    parent = self()

    spawn_link(fn ->
      {:ok, client_socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(client_socket, 0)

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(response_body)}\r\nConnection: close\r\n\r\n" <>
          response_body

      :gen_tcp.send(client_socket, response)
      :gen_tcp.close(client_socket)
      send(parent, :done)
    end)

    port
  end

  defp base_params do
    %{
      info_hash: :crypto.hash(:sha, "info"),
      peer_id: :crypto.hash(:sha, "peer"),
      port: 6881,
      uploaded: 0,
      downloaded: 0,
      left: 1000
    }
  end

  test "announce/3 parses a compact-peers response" do
    peers_bin = <<127, 0, 0, 1, 6881::16>>
    body = Bencode.encode([{"interval", 1800}, {"peers", peers_bin}, {"complete", 5}, {"incomplete", 2}])
    port = start_fake_tracker(body)

    assert {:ok, result} = Http.announce("http://127.0.0.1:#{port}/announce", base_params())
    assert result.interval == 1800
    assert result.peers == [{{127, 0, 0, 1}, 6881}]
    assert result.seeders == 5
    assert result.leechers == 2

    assert_receive :done, 1000
  end

  test "announce/3 parses a non-compact (dict list) peers response" do
    peers_list = [[{"ip", "10.0.0.5"}, {"port", 6969}]]
    body = Bencode.encode([{"interval", 900}, {"peers", peers_list}])
    port = start_fake_tracker(body)

    assert {:ok, result} = Http.announce("http://127.0.0.1:#{port}/announce", base_params())
    assert result.peers == [{{10, 0, 0, 5}, 6969}]
  end

  test "announce/3 surfaces a tracker failure reason as an error" do
    body = Bencode.encode([{"failure reason", "torrent not registered"}])
    port = start_fake_tracker(body)

    assert {:error, {:tracker_failure, "torrent not registered"}} =
             Http.announce("http://127.0.0.1:#{port}/announce", base_params())
  end

  test "announce/3 byte-exact percent-encodes raw info_hash/peer_id bytes in the query string" do
    # info_hash containing bytes that URI.encode_www_form would mishandle
    # (e.g. treating space as '+', or leaving reserved chars as-is).
    params = %{base_params() | info_hash: <<0, 255, 32, 43, 126>>}
    body = Bencode.encode([{"interval", 1800}, {"peers", ""}])

    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    spawn_link(fn ->
      {:ok, client_socket} = :gen_tcp.accept(listen_socket)
      {:ok, request} = :gen_tcp.recv(client_socket, 0)
      send(parent, {:request, request})

      response =
        "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body

      :gen_tcp.send(client_socket, response)
      :gen_tcp.close(client_socket)
    end)

    {:ok, _result} = Http.announce("http://127.0.0.1:#{port}/announce", params)
    assert_receive {:request, request}, 1000

    assert request =~ "info_hash=%00%FF%20%2B~"
  end
end
