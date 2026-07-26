defmodule Flux.Torrent.Dht.RoutingTable do
  @moduledoc """
  A flat, capped set of known DHT nodes — deliberately not a full Kademlia
  k-bucket tree (same simplicity trade-off already made for
  `Flux.Torrent.PiecePicker`'s sequential picker vs. rarest-first): good
  enough to find closest-by-XOR-distance nodes for a lookup, without the
  extra bookkeeping a real bucket-split tree needs. When over capacity, the
  single node with the *greatest* distance from our own id is evicted,
  keeping the table biased toward nodes nearest us.
  """

  @max_nodes 200

  defstruct [:our_id, nodes: %{}]

  @type node_entry :: {binary(), :inet.ip4_address(), :inet.port_number()}
  @type t :: %__MODULE__{our_id: binary(), nodes: %{binary() => {:inet.ip4_address(), :inet.port_number()}}}

  @spec new(binary()) :: t()
  def new(our_id), do: %__MODULE__{our_id: our_id}

  @spec add_node(t(), binary(), :inet.ip4_address(), :inet.port_number()) :: t()
  def add_node(table, node_id, _ip, _port) when node_id == table.our_id, do: table

  def add_node(table, node_id, ip, port) do
    nodes = Map.put(table.nodes, node_id, {ip, port})

    if map_size(nodes) > @max_nodes do
      furthest = Enum.max_by(Map.keys(nodes), &distance(table.our_id, &1))
      %{table | nodes: Map.delete(nodes, furthest)}
    else
      %{table | nodes: nodes}
    end
  end

  @spec remove_node(t(), binary()) :: t()
  def remove_node(table, node_id), do: %{table | nodes: Map.delete(table.nodes, node_id)}

  @doc "The `k` known nodes closest (by XOR distance) to `target_id`."
  @spec closest_nodes(t(), binary(), pos_integer()) :: [node_entry()]
  def closest_nodes(table, target_id, k \\ 8) do
    table.nodes
    |> Enum.sort_by(fn {node_id, _} -> distance(target_id, node_id) end)
    |> Enum.take(k)
    |> Enum.map(fn {node_id, {ip, port}} -> {node_id, ip, port} end)
  end

  @spec size(t()) :: non_neg_integer()
  def size(table), do: map_size(table.nodes)

  @doc "XOR distance between two 20-byte node ids, as a plain integer for ordering/comparison."
  @spec distance(binary(), binary()) :: non_neg_integer()
  def distance(id_a, id_b) do
    Bitwise.bxor(:binary.decode_unsigned(id_a), :binary.decode_unsigned(id_b))
  end
end
