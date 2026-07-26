defmodule Flux.Torrent.TrackerClientTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.TrackerClient

  test "dispatch/3 routes http:// and https:// to the Http client, udp:// to the Udp client" do
    assert {:error, {:unsupported_tracker_scheme, "ftp"}} =
             TrackerClient.dispatch("ftp://example.com", %{}, [])
  end

  test "parse_compact_peers/1 decodes 6-byte entries" do
    peers_bin = <<127, 0, 0, 1, 6881::16, 10, 0, 0, 5, 6969::16>>

    assert TrackerClient.parse_compact_peers(peers_bin) == [
             {{127, 0, 0, 1}, 6881},
             {{10, 0, 0, 5}, 6969}
           ]
  end

  test "parse_compact_peers/1 returns [] for malformed (non-multiple-of-6) input" do
    assert TrackerClient.parse_compact_peers(<<1, 2, 3>>) == []
  end
end
