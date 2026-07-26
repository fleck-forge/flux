defmodule Flux.Torrent.TrackerClient.Udp do
  @moduledoc """
  BEP 15 UDP tracker announce over `:gen_udp`. Two round trips: connect
  (exchanging a short-lived connection_id) then announce, each matching a
  random transaction_id against the reply so a stray/malformed packet on
  the socket can't be mistaken for our response.
  """

  @behaviour Flux.Torrent.TrackerClient

  alias Flux.Torrent.TrackerClient

  @protocol_magic 0x41727101980
  @max_connect_attempts 4

  @impl true
  def announce(tracker_url, params, opts \\ []) do
    uri = URI.parse(tracker_url)
    timeout = Keyword.get(opts, :timeout, 15_000)

    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]),
         {:ok, ip} <- resolve(uri.host),
         {:ok, connection_id} <- connect(socket, ip, uri.port, timeout, 0),
         {:ok, result} <- do_announce(socket, ip, uri.port, connection_id, params, timeout) do
      :gen_udp.close(socket)
      {:ok, result}
    end
  end

  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(_socket, _ip, _port, _timeout, attempt) when attempt >= @max_connect_attempts do
    {:error, :connect_timeout}
  end

  defp connect(socket, ip, port, timeout, attempt) do
    transaction_id = :rand.uniform(0xFFFFFFFF)
    packet = <<@protocol_magic::64, 0::32, transaction_id::32>>
    wait = min(round(15_000 * :math.pow(2, attempt)), timeout)

    with :ok <- :gen_udp.send(socket, ip, port, packet) do
      case :gen_udp.recv(socket, 0, wait) do
        {:ok, {_ip, _port, <<0::32, ^transaction_id::32, connection_id::64>>}} ->
          {:ok, connection_id}

        {:ok, _other} ->
          connect(socket, ip, port, timeout, attempt + 1)

        {:error, :timeout} ->
          connect(socket, ip, port, timeout, attempt + 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_announce(socket, ip, port, connection_id, params, timeout) do
    transaction_id = :rand.uniform(0xFFFFFFFF)

    packet =
      <<connection_id::64, 1::32, transaction_id::32, params.info_hash::binary-size(20),
        params.peer_id::binary-size(20), params.downloaded::64, params.left::64,
        params.uploaded::64, event_code(params[:event])::32, 0::32, 0::32,
        Map.get(params, :numwant, -1)::32-signed, params.port::16>>

    with :ok <- :gen_udp.send(socket, ip, port, packet) do
      case :gen_udp.recv(socket, 0, timeout) do
        {:ok,
         {_ip, _port,
          <<1::32, ^transaction_id::32, interval::32, leechers::32, seeders::32,
            peers_bin::binary>>}} ->
          {:ok,
           %{
             interval: interval,
             peers: TrackerClient.parse_compact_peers(peers_bin),
             seeders: seeders,
             leechers: leechers
           }}

        {:ok, _other} ->
          {:error, :bad_announce_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp event_code(:started), do: 2
  defp event_code(:completed), do: 1
  defp event_code(:stopped), do: 3
  defp event_code(_), do: 0
end
