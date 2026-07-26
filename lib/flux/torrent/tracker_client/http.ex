defmodule Flux.Torrent.TrackerClient.Http do
  @moduledoc """
  BEP 3 HTTP(S) tracker announce over `Req`. The response body is raw
  bencoded bytes, not JSON — fetched with `decode_body: false` and decoded
  ourselves with `Flux.Bencode`.
  """

  @behaviour Flux.Torrent.TrackerClient

  alias Flux.Bencode
  alias Flux.Torrent.TrackerClient

  @impl true
  def announce(tracker_url, params, opts \\ []) do
    url = tracker_url <> separator(tracker_url) <> build_query(params)
    timeout = Keyword.get(opts, :receive_timeout, 15_000)

    case Req.get(url, decode_body: false, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} -> parse_response(body)
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")

  defp build_query(params) do
    [
      {"info_hash", percent_encode_bytes(params.info_hash)},
      {"peer_id", percent_encode_bytes(params.peer_id)},
      {"port", to_string(params.port)},
      {"uploaded", to_string(params.uploaded)},
      {"downloaded", to_string(params.downloaded)},
      {"left", to_string(params.left)},
      {"compact", "1"}
    ]
    |> maybe_add("event", event_param(params[:event]))
    |> maybe_add("numwant", params[:numwant] && to_string(params[:numwant]))
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp event_param(nil), do: nil
  defp event_param(event) when event in [:started, :stopped, :completed], do: to_string(event)

  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, key, value), do: list ++ [{key, value}]

  # Trackers expect raw-byte percent-escaping of info_hash/peer_id (any byte
  # outside the unreserved set escaped as %XX) — `URI.encode_www_form/1`
  # and `URI.encode/1` both apply form/URI text-encoding rules that don't
  # match this and can mishandle arbitrary binary content.
  defp percent_encode_bytes(bin) do
    for <<byte <- bin>>, into: "", do: percent_encode_byte(byte)
  end

  defp percent_encode_byte(byte)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?., ?-, ?_, ?~] do
    <<byte>>
  end

  defp percent_encode_byte(byte) do
    "%" <> (Integer.to_string(byte, 16) |> String.pad_leading(2, "0") |> String.upcase())
  end

  defp parse_response(body) do
    with {:ok, dict} <- Bencode.decode_full(body) do
      case dict_get(dict, "failure reason") do
        nil -> {:ok, build_result(dict)}
        reason -> {:error, {:tracker_failure, reason}}
      end
    end
  end

  defp build_result(dict) do
    %{
      interval: dict_get(dict, "interval") || 1800,
      peers: parse_peers(dict_get(dict, "peers")),
      seeders: dict_get(dict, "complete"),
      leechers: dict_get(dict, "incomplete")
    }
  end

  defp parse_peers(bin) when is_binary(bin), do: TrackerClient.parse_compact_peers(bin)

  defp parse_peers(list) when is_list(list) do
    for entry <- list do
      ip = dict_get(entry, "ip")
      port = dict_get(entry, "port")
      {parse_ip(ip), port}
    end
  end

  defp parse_peers(_), do: []

  defp parse_ip(ip_str) when is_binary(ip_str) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_str))
    ip
  end

  defp dict_get(pairs, key) do
    Enum.find_value(pairs, fn {k, v} -> if k == key, do: v end)
  end
end
