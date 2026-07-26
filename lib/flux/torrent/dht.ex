defmodule Flux.Torrent.Dht do
  @moduledoc """
  BEP 5 Kademlia DHT — a single, application-wide node (not per-torrent),
  matching how real clients run exactly one DHT node regardless of how many
  torrents are active. Gives Flux a much larger peer pool than tracker
  announces alone provide, and is also what makes a magnet link with zero
  trackers viable at all.

  Owns one shared `:gen_udp` socket, a flat capped `RoutingTable`, and a
  `transaction_id => from` waiter map so `await_response/2` can be a normal
  blocking `GenServer.call` from the *caller's* perspective while this
  GenServer itself never blocks on network I/O — many lookups (across many
  torrents) can have transactions in flight concurrently without blocking
  each other or routing-table/responder duties.

  v1 scope: implements `get_peers` (what we need) and responds correctly to
  `ping`/`find_node`/`get_peers`/`announce_peer` (needed to be treated as a
  legitimate participant other nodes will route through — a node that never
  responds gets pruned). No persistent routing-table file across restarts,
  no announce_peer bookkeeping for other torrents' swarms (we always answer
  get_peers with closest-nodes, never `values`, since we don't track that).
  """

  use GenServer
  require Logger

  alias Flux.Torrent.Dht.{Krpc, RoutingTable}

  @bootstrap_nodes [
    {~c"router.bittorrent.com", 6881},
    {~c"dht.transmissionbt.com", 6881},
    {~c"router.utorrent.com", 6881}
  ]

  defstruct [:our_id, :socket, :routing_table, :token_secret, waiters: %{}, transaction_counter: 0]

  ## Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The actual bound UDP port (useful when configured with port 0 in tests)."
  def port, do: GenServer.call(__MODULE__, :port)

  @doc """
  Fire-and-forget send of a KRPC query to `dest`. Use this only when the
  response doesn't matter to the caller (e.g. bootstrap `find_node`s — any
  response we get still populates the routing table via the generic
  `handle_incoming_response` path, whether or not anyone's registered as a
  waiter for it). If you need the actual response, use `query_and_wait/4`
  instead — sending and registering-a-waiter as two separate calls has a
  race: a fast responder (trivially possible on loopback, and not
  impossible over a real network either) can have its reply arrive and be
  silently dropped *before* a separate `await_response` call ever
  registers the waiter for it.
  """
  def send_query(dest, query_name, args_pairs) do
    GenServer.call(__MODULE__, {:send_query, dest, query_name, args_pairs})
  end

  @doc """
  Sends a KRPC query and waits for its response, atomically — the waiter
  is registered as part of the same `handle_call` that sends the packet,
  so no response can possibly be processed (the `Dht` GenServer only
  handles one message at a time) before this call is waiting for it.
  """
  def query_and_wait(dest, query_name, args_pairs, timeout \\ 3000) do
    GenServer.call(__MODULE__, {:query_and_wait, dest, query_name, args_pairs, timeout}, timeout + 1000)
  end

  def routing_table_snapshot, do: GenServer.call(__MODULE__, :routing_table_snapshot)

  @doc """
  Iterative Kademlia lookup for peers of `info_hash`. A plain function (not
  a process) — it runs in the calling process (Session.Worker spawns a
  one-shot process for this), driving `send_query`/`await_response` calls
  against the shared `Dht` GenServer, so a slow multi-round lookup never
  blocks the GenServer's socket/responder duties.
  """
  @spec get_peers(binary(), keyword()) :: {:ok, [{:inet.ip4_address(), :inet.port_number()}]}
  def get_peers(info_hash, opts \\ []) do
    alpha = Keyword.get(opts, :alpha, 3)
    max_rounds = Keyword.get(opts, :max_rounds, 8)
    timeout = Keyword.get(opts, :per_query_timeout, 3000)

    case routing_table_snapshot() do
      {:ok, table} ->
        initial = RoutingTable.closest_nodes(table, info_hash, 20)
        {peers, _queried, _candidates} = do_lookup(info_hash, initial, MapSet.new(), MapSet.new(), alpha, max_rounds, timeout)
        {:ok, MapSet.to_list(peers)}

      _ ->
        {:ok, []}
    end
  end

  defp do_lookup(_info_hash, _candidates, queried, peers, _alpha, 0, _timeout), do: {peers, queried, []}

  defp do_lookup(info_hash, candidates, queried, peers, alpha, rounds_left, timeout) do
    to_query =
      candidates
      |> Enum.reject(fn {id, _ip, _port} -> MapSet.member?(queried, id) end)
      |> Enum.take(alpha)

    if to_query == [] do
      {peers, queried, candidates}
    else
      {new_peers, new_nodes, new_queried} =
        to_query
        |> Enum.map(fn {node_id, ip, port} -> query_one(info_hash, node_id, ip, port, timeout) end)
        |> Enum.reduce({peers, [], queried}, &fold_lookup_result/2)

      known_ids = MapSet.new(candidates, fn {id, _, _} -> id end)

      fresh_nodes =
        new_nodes
        |> Enum.uniq_by(fn {id, _ip, _port} -> id end)
        |> Enum.reject(fn {id, _ip, _port} -> MapSet.member?(known_ids, id) end)

      merged =
        (candidates ++ fresh_nodes)
        |> Enum.uniq_by(fn {id, _ip, _port} -> id end)
        |> Enum.sort_by(fn {id, _ip, _port} -> RoutingTable.distance(info_hash, id) end)

      do_lookup(info_hash, merged, new_queried, new_peers, alpha, rounds_left - 1, timeout)
    end
  end

  defp fold_lookup_result({:ok, node_id, found_peers, found_nodes}, {p_acc, n_acc, q_acc}) do
    {MapSet.union(p_acc, MapSet.new(found_peers)), n_acc ++ found_nodes, MapSet.put(q_acc, node_id)}
  end

  defp fold_lookup_result({:error, node_id}, {p_acc, n_acc, q_acc}) do
    {p_acc, n_acc, MapSet.put(q_acc, node_id)}
  end

  defp query_one(info_hash, node_id, ip, port, timeout) do
    case query_and_wait({ip, port}, "get_peers", [{"info_hash", info_hash}], timeout) do
      {:ok, %{type: :response} = msg} -> {:ok, node_id, msg.values, msg.nodes}
      _ -> {:error, node_id}
    end
  end

  ## Server

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 6881)
    our_id = :crypto.strong_rand_bytes(20)

    base_state = %__MODULE__{
      our_id: our_id,
      routing_table: RoutingTable.new(our_id),
      token_secret: :crypto.strong_rand_bytes(20)
    }

    case :gen_udp.open(port, [:binary, active: true]) do
      {:ok, socket} ->
        send(self(), :bootstrap)
        {:ok, %{base_state | socket: socket}}

      {:error, reason} ->
        Logger.warning("Dht: could not open UDP socket on port #{port} (#{inspect(reason)})")
        {:ok, base_state}
    end
  end

  @impl true
  def handle_call(:port, _from, %{socket: nil} = state), do: {:reply, nil, state}
  def handle_call(:port, _from, state), do: {:reply, elem(:inet.port(state.socket), 1), state}

  def handle_call(:routing_table_snapshot, _from, state) do
    {:reply, {:ok, state.routing_table}, state}
  end

  def handle_call({:send_query, dest, query_name, args_pairs}, _from, state) do
    {tid, state} = do_send_query(state, dest, query_name, args_pairs)
    {:reply, if(tid, do: {:ok, tid}, else: {:error, :no_socket}), state}
  end

  def handle_call({:query_and_wait, _dest, _query_name, _args_pairs, _timeout}, _from, %{socket: nil} = state) do
    {:reply, {:error, :no_socket}, state}
  end

  def handle_call({:query_and_wait, dest, query_name, args_pairs, timeout}, from, state) do
    {tid, state} = do_send_query(state, dest, query_name, args_pairs)
    timer = Process.send_after(self(), {:await_timeout, tid}, timeout)
    {:noreply, %{state | waiters: Map.put(state.waiters, tid, {from, timer})}}
  end

  defp do_send_query(%{socket: nil} = state, _dest, _query_name, _args), do: {nil, state}

  defp do_send_query(state, {ip, port}, query_name, args_pairs) do
    tid = <<state.transaction_counter::16>>
    full_args = [{"id", state.our_id} | args_pairs]
    :gen_udp.send(state.socket, ip, port, Krpc.encode_query(tid, query_name, full_args))
    {tid, %{state | transaction_counter: state.transaction_counter + 1}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    state =
      Enum.reduce(@bootstrap_nodes, state, fn {host, port}, acc ->
        case :inet.getaddr(host, :inet) do
          {:ok, ip} -> elem(do_send_query(acc, {ip, port}, "find_node", [{"target", acc.our_id}]), 1)
          {:error, _reason} -> acc
        end
      end)

    {:noreply, state}
  end

  def handle_info({:await_timeout, tid}, state) do
    case Map.pop(state.waiters, tid) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    state =
      case Krpc.decode(data) do
        {:ok, %{type: :query} = msg} -> handle_incoming_query(state, msg, ip, port)
        {:ok, %{type: :response} = msg} -> handle_incoming_response(state, msg, ip, port)
        {:ok, %{type: :error} = msg} -> resolve_waiter(state, msg.transaction_id, {:error, msg})
        {:error, _reason} -> state
      end

    {:noreply, state}
  end

  defp handle_incoming_response(state, msg, ip, port) do
    state
    |> resolve_waiter(msg.transaction_id, {:ok, msg})
    |> maybe_add_node(msg.id, ip, port)
  end

  defp resolve_waiter(state, tid, result) do
    case Map.pop(state.waiters, tid) do
      {nil, _waiters} ->
        state

      {{from, timer}, waiters} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{state | waiters: waiters}
    end
  end

  defp maybe_add_node(state, nil, _ip, _port), do: state

  defp maybe_add_node(state, node_id, ip, port) do
    %{state | routing_table: RoutingTable.add_node(state.routing_table, node_id, ip, port)}
  end

  defp handle_incoming_query(state, msg, ip, port) do
    state = maybe_add_node(state, msg.args.id, ip, port)

    case msg.query do
      "ping" -> respond_ping(state, msg, ip, port)
      "find_node" -> respond_find_node(state, msg, ip, port)
      "get_peers" -> respond_get_peers(state, msg, ip, port)
      "announce_peer" -> respond_announce_peer(state, msg, ip, port)
      _ -> :ok
    end

    state
  end

  defp respond_ping(state, msg, ip, port) do
    send_response(state, msg.transaction_id, [{"id", state.our_id}], ip, port)
  end

  defp respond_find_node(state, msg, ip, port) do
    target = msg.args.target || state.our_id
    nodes = RoutingTable.closest_nodes(state.routing_table, target, 8)

    send_response(
      state,
      msg.transaction_id,
      [{"id", state.our_id}, {"nodes", Krpc.encode_compact_nodes(nodes)}],
      ip,
      port
    )
  end

  defp respond_get_peers(state, msg, ip, port) do
    target = msg.args.info_hash || state.our_id
    nodes = RoutingTable.closest_nodes(state.routing_table, target, 8)
    token = make_token(state, ip)

    send_response(
      state,
      msg.transaction_id,
      [{"id", state.our_id}, {"token", token}, {"nodes", Krpc.encode_compact_nodes(nodes)}],
      ip,
      port
    )
  end

  defp respond_announce_peer(state, msg, ip, port) do
    if valid_token?(state, ip, msg.args.token) do
      send_response(state, msg.transaction_id, [{"id", state.our_id}], ip, port)
    else
      packet = Krpc.encode_error(msg.transaction_id, 203, "Bad token")
      :gen_udp.send(state.socket, ip, port, packet)
    end
  end

  defp send_response(state, tid, pairs, ip, port) do
    :gen_udp.send(state.socket, ip, port, Krpc.encode_response(tid, pairs))
  end

  defp make_token(state, ip) do
    ip_bin = ip |> Tuple.to_list() |> :erlang.list_to_binary()
    :crypto.hash(:sha, state.token_secret <> ip_bin) |> binary_part(0, 8)
  end

  defp valid_token?(state, ip, token), do: token == make_token(state, ip)
end
