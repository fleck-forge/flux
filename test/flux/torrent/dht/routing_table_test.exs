defmodule Flux.Torrent.Dht.RoutingTableTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Dht.RoutingTable

  defp id(seed), do: :crypto.hash(:sha, seed)

  test "new/1 starts empty" do
    table = RoutingTable.new(id("me"))
    assert RoutingTable.size(table) == 0
  end

  test "add_node/4 adds a node, ignoring our own id" do
    our_id = id("me")
    table = RoutingTable.new(our_id)

    table = RoutingTable.add_node(table, id("a"), {1, 2, 3, 4}, 6881)
    assert RoutingTable.size(table) == 1

    table = RoutingTable.add_node(table, our_id, {5, 6, 7, 8}, 1000)
    assert RoutingTable.size(table) == 1
  end

  test "remove_node/2" do
    table = RoutingTable.new(id("me")) |> RoutingTable.add_node(id("a"), {1, 2, 3, 4}, 6881)
    table = RoutingTable.remove_node(table, id("a"))
    assert RoutingTable.size(table) == 0
  end

  test "closest_nodes/3 returns nodes ordered by XOR distance to the target" do
    our_id = id("me")
    a = id("a")
    b = id("b")
    c = id("c")

    table =
      RoutingTable.new(our_id)
      |> RoutingTable.add_node(a, {1, 1, 1, 1}, 1)
      |> RoutingTable.add_node(b, {2, 2, 2, 2}, 2)
      |> RoutingTable.add_node(c, {3, 3, 3, 3}, 3)

    # Distance to `a` itself should put `a` first.
    [{closest_id, _ip, _port} | _rest] = RoutingTable.closest_nodes(table, a, 3)
    assert closest_id == a
  end

  test "closest_nodes/3 respects the k limit" do
    table =
      Enum.reduce(1..10, RoutingTable.new(id("me")), fn i, acc ->
        RoutingTable.add_node(acc, id("n#{i}"), {1, 1, 1, 1}, i)
      end)

    assert length(RoutingTable.closest_nodes(table, id("target"), 3)) == 3
  end

  test "evicts the furthest node once over capacity" do
    our_id = id("me")
    # Flip only the last bit of our own id: XOR distance of exactly 1, the
    # closest any distinct node could possibly be — guaranteed to survive
    # whatever eviction happens.
    <<prefix::binary-size(19), last_byte>> = our_id
    closest = <<prefix::binary, Bitwise.bxor(last_byte, 1)>>

    table =
      Enum.reduce(1..200, RoutingTable.new(our_id), fn i, acc ->
        RoutingTable.add_node(acc, id("filler#{i}"), {1, 1, 1, 1}, i)
      end)

    table = RoutingTable.add_node(table, closest, {9, 9, 9, 9}, 9999)

    assert RoutingTable.size(table) == 200
    assert Map.has_key?(table.nodes, closest)
  end
end
