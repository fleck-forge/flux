defmodule Flux.Torrent.Dht.KrpcTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Dht.Krpc

  @our_id :crypto.hash(:sha, "our-node")
  @target :crypto.hash(:sha, "target-node")
  @info_hash :crypto.hash(:sha, "some-torrent")

  describe "query encode/decode" do
    test "ping" do
      encoded = Krpc.encode_query("aa", "ping", [{"id", @our_id}])
      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.type == :query
      assert msg.transaction_id == "aa"
      assert msg.query == "ping"
      assert msg.args.id == @our_id
    end

    test "find_node" do
      encoded =
        Krpc.encode_query("bb", "find_node", [{"id", @our_id}, {"target", @target}])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.query == "find_node"
      assert msg.args.id == @our_id
      assert msg.args.target == @target
    end

    test "get_peers" do
      encoded =
        Krpc.encode_query("cc", "get_peers", [{"id", @our_id}, {"info_hash", @info_hash}])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.query == "get_peers"
      assert msg.args.info_hash == @info_hash
    end

    test "announce_peer" do
      encoded =
        Krpc.encode_query("dd", "announce_peer", [
          {"id", @our_id},
          {"info_hash", @info_hash},
          {"port", 6881},
          {"token", "tok123"},
          {"implied_port", 0}
        ])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.query == "announce_peer"
      assert msg.args.port == 6881
      assert msg.args.token == "tok123"
      assert msg.args.implied_port == 0
    end
  end

  describe "response encode/decode" do
    test "ping response" do
      encoded = Krpc.encode_response("aa", [{"id", @our_id}])
      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.type == :response
      assert msg.transaction_id == "aa"
      assert msg.id == @our_id
      assert msg.nodes == []
      assert msg.values == []
    end

    test "find_node response with compact nodes" do
      nodes = [
        {:crypto.hash(:sha, "n1"), {127, 0, 0, 1}, 6881},
        {:crypto.hash(:sha, "n2"), {192, 168, 1, 5}, 51413}
      ]

      encoded =
        Krpc.encode_response("bb", [{"id", @our_id}, {"nodes", Krpc.encode_compact_nodes(nodes)}])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.nodes == nodes
    end

    test "get_peers response with values (peer list)" do
      peers_bin = [<<127, 0, 0, 1, 6881::16>>, <<10, 0, 0, 5, 51413::16>>]

      encoded =
        Krpc.encode_response("cc", [{"id", @our_id}, {"token", "tok"}, {"values", peers_bin}])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.token == "tok"
      assert msg.values == [{{127, 0, 0, 1}, 6881}, {{10, 0, 0, 5}, 51413}]
    end

    test "get_peers response with closer nodes instead of values" do
      nodes = [{:crypto.hash(:sha, "n1"), {8, 8, 8, 8}, 6881}]

      encoded =
        Krpc.encode_response("cc", [
          {"id", @our_id},
          {"token", "tok"},
          {"nodes", Krpc.encode_compact_nodes(nodes)}
        ])

      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.nodes == nodes
      assert msg.values == []
    end
  end

  describe "error encode/decode" do
    test "round-trips" do
      encoded = Krpc.encode_error("ee", 201, "Generic Error")
      assert {:ok, msg} = Krpc.decode(encoded)
      assert msg.type == :error
      assert msg.transaction_id == "ee"
      assert msg.code == 201
      assert msg.message == "Generic Error"
    end
  end

  describe "malformed input" do
    test "unknown message type" do
      bad = Flux.Bencode.encode([{"t", "x"}, {"y", "z"}])
      assert {:error, :unknown_message_type} = Krpc.decode(bad)
    end

    test "not bencode at all" do
      assert {:error, _} = Krpc.decode("not bencode")
    end
  end

  describe "compact nodes/peers helpers directly" do
    test "encode_compact_nodes/decode_compact_nodes round trip" do
      nodes = [{:crypto.hash(:sha, "a"), {1, 2, 3, 4}, 1000}]
      assert Krpc.decode_compact_nodes(Krpc.encode_compact_nodes(nodes)) == nodes
    end

    test "decode_compact_nodes rejects malformed length" do
      assert Krpc.decode_compact_nodes(<<1, 2, 3>>) == []
    end

    test "decode_compact_peers ignores non-6-byte entries" do
      assert Krpc.decode_compact_peers(["short", <<1, 2, 3, 4, 5, 6>>]) == [{{1, 2, 3, 4}, 1286}]
    end
  end
end
