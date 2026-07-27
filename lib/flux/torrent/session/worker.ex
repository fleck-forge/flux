defmodule Flux.Torrent.Session.Worker do
  @moduledoc """
  One GenServer per active download — the per-torrent brain. Resolves
  metadata (immediately for a `.torrent` add, asynchronously via BEP 9/10
  peer exchange for a magnet), runs the tracker announce loop, starts peer
  connections, drives the piece picker and choking, persists progress, and
  keeps running after completion to seed.

  Known v1 simplifications (documented rather than silently absent):
  request pipelining is one in-flight block per peer at a time (not the
  usual 5-10 pipelined requests real clients use for throughput); a choked
  peer's in-flight requests aren't explicitly timed out/retried; per-peer
  download rate for the choking algorithm isn't tracked (treated as 0 for
  all, so `Flux.Torrent.Choker` picks arbitrarily among interested peers
  rather than by actual rate). None of these affect correctness, only
  efficiency, and are reasonable to defer past v1.
  """

  use GenServer
  require Logger

  alias Flux.Downloads

  alias Flux.Torrent.{
    MetaInfo,
    Bitfield,
    PiecePicker,
    Choker,
    TrackerClient,
    Storage,
    PeerConnection,
    Dht
  }

  @block_size 16_384
  @max_peers 30
  @choke_interval 10_000
  @peer_fill_interval 5_000
  @dht_tick_interval 60_000
  @min_announce_interval 30

  defstruct [
    :download_id,
    :info_hash,
    :our_peer_id,
    :save_path,
    :meta_info,
    :storage_pid,
    trackers: [],
    tracker_index: 0,
    peers: %{},
    peer_info: %{},
    peer_addresses: %{},
    pending: %{},
    known_peers: MapSet.new(),
    tried_peers: MapSet.new(),
    dht_lookup_pid: nil,
    choke_state: %{},
    unchoked_by: MapSet.new(),
    picker: nil,
    our_bitfield: nil,
    uploaded: 0,
    downloaded: 0,
    announced?: false,
    tick_count: 0,
    metadata_chunks: %{},
    metadata_total_size: nil,
    metadata_requested_from: nil,
    tracker_seeders: nil,
    tracker_leechers: nil
  ]

  def start_link(download_id), do: GenServer.start_link(__MODULE__, download_id)

  ## Startup

  @impl true
  def init(download_id) do
    download = Downloads.get_download!(download_id)
    Registry.register(Flux.Torrent.Registry, download.info_hash, nil)

    trackers = decode_trackers(download.trackers)

    state = %__MODULE__{
      download_id: download_id,
      info_hash: download.info_hash,
      our_peer_id: :crypto.strong_rand_bytes(20),
      save_path: download.save_path,
      trackers: trackers,
      uploaded: download.uploaded,
      downloaded: download.downloaded
    }

    # DHT gives every session a peer-discovery path independent of trackers
    # (including a magnet with none at all), so it's scheduled unconditionally
    # here rather than only once metadata/storage exist below.
    schedule_dht_tick(0)

    cond do
      download.info_dict ->
        with {:ok, meta_info} <- MetaInfo.parse_info_dict(download.info_dict, trackers) do
          start_with_metadata(state, meta_info, download)
        else
          {:error, reason} ->
            Downloads.mark_failed(
              download,
              "could not parse stored torrent metadata: #{inspect(reason)}"
            )

            :ignore
        end

      true ->
        schedule_announce(0)
        {:ok, state}
    end
  end

  defp decode_trackers(json) do
    case Jason.decode(json || "[]") do
      {:ok, tiers} when is_list(tiers) ->
        Enum.map(tiers, fn tier -> Enum.filter(tier, &is_binary/1) end)

      _ ->
        []
    end
  end

  defp start_with_metadata(state, meta_info, download) do
    with {:ok, storage_pid} <-
           Storage.start_link(meta_info: meta_info, save_path: state.save_path) do
      Downloads.mark_checking(download)
      {:ok, verified_bitfield} = Storage.verify_existing(storage_pid)

      downloaded_bytes = bytes_for_bitfield(verified_bitfield, meta_info)

      final_state =
        if downloaded_bytes >= meta_info.total_length, do: :completed, else: :downloading

      {:ok, _} =
        Downloads.update_download(download, %{
          downloaded: downloaded_bytes,
          bitfield: Bitfield.to_wire(verified_bitfield),
          state: final_state,
          # Completing right here (before a single peer connection this
          # session) means the file was already fully intact on disk —
          # surfaced distinctly in the UI so it doesn't look like a
          # multi-GB download that impossibly finished in seconds.
          verified_from_disk: final_state == :completed
        })

      picker =
        PiecePicker.new(
          length(meta_info.pieces),
          meta_info.piece_length,
          meta_info.total_length,
          verified_bitfield
        )

      state = %{
        state
        | meta_info: meta_info,
          storage_pid: storage_pid,
          picker: picker,
          our_bitfield: verified_bitfield,
          downloaded: downloaded_bytes
      }

      # For a magnet, peers can already be connected (found via tracker/DHT
      # and used to fetch this very metadata) before `meta_info` existed —
      # `:interested` is only sent at `peer_connected` time when metadata is
      # already known, so anyone already connected needs it sent now instead.
      for {_peer_id, pid} <- state.peers, do: PeerConnection.send_message(pid, :interested)

      schedule_choke_tick()
      schedule_peer_fill_tick()
      schedule_announce(0)
      {:ok, state}
    else
      {:error, reason} ->
        Downloads.mark_failed(download, "could not initialize storage: #{inspect(reason)}")
        :ignore
    end
  end

  ## handle_call

  @impl true
  def handle_call(:connection_info, _from, state) do
    {:reply,
     [
       session_pid: self(),
       info_hash: state.info_hash,
       our_peer_id: state.our_peer_id,
       storage_pid: state.storage_pid,
       piece_count: piece_count(state),
       our_bitfield: our_bitfield_wire(state),
       raw_info_bytes: state.meta_info && state.meta_info.raw_info_bytes,
       metadata_size: state.meta_info && byte_size(state.meta_info.raw_info_bytes)
     ], state}
  end

  def handle_call(:pause, _from, state), do: {:reply, :ok, state}
  def handle_call({:remove, _delete_files?}, _from, state), do: {:reply, :ok, state}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       peer_count: map_size(state.peers),
       connecting_count: map_size(state.pending),
       tracker_seeders: state.tracker_seeders,
       tracker_leechers: state.tracker_leechers
     }, state}
  end

  ## handle_info — announce loop, choke tick, peer-process monitoring

  @impl true
  def handle_info(:announce, state), do: {:noreply, do_announce(state)}

  def handle_info(:choke_tick, state) do
    decisions = Choker.decide(state.choke_state, 4, optimistic?: rem(state.tick_count, 3) == 0)

    for {peer_id, decision} <- decisions, pid = Map.get(state.peers, peer_id), pid != nil do
      PeerConnection.send_message(pid, decision)
    end

    schedule_choke_tick()
    {:noreply, %{state | tick_count: state.tick_count + 1}}
  end

  # Tops up peer connections independently of the tracker announce cycle
  # (which can be many minutes apart) — without this, a failed/disconnected
  # peer or a connection attempt that never panned out just sits empty
  # until the next scheduled announce. This keeps retrying from the full
  # set of peers this session has ever learned about (not just the most
  # recent announce's list), so a peer that failed once isn't permanently
  # given up on.
  def handle_info(:peer_fill_tick, state) do
    schedule_peer_fill_tick()
    {:noreply, connect_to_peers(state, MapSet.to_list(state.known_peers))}
  end

  # A DHT lookup (multi-round, several seconds) runs in its own spawned
  # process rather than inline here, so it never blocks announce/choke/peer
  # handling — only one runs at a time (`dht_lookup_pid` guards re-entry;
  # cleared again once its :DOWN arrives below, whether it finished normally
  # or crashed).
  def handle_info(:dht_tick, state) do
    schedule_dht_tick()
    {:noreply, start_dht_lookup(state)}
  end

  def handle_info({:dht_peers_result, pid, {:ok, peers}}, %{dht_lookup_pid: pid} = state) do
    state = %{state | known_peers: MapSet.union(state.known_peers, MapSet.new(peers))}
    {:noreply, connect_to_peers(state, peers)}
  end

  def handle_info({:dht_peers_result, _pid, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{dht_lookup_pid: pid} = state) do
    {:noreply, %{state | dht_lookup_pid: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.peer_info, pid) do
      nil ->
        # Never finished handshaking — connect/handshake failure surfaces
        # here (as this monitored process exiting), not as an error return
        # from starting it, since the connect itself is asynchronous now.
        case Map.get(state.pending, pid) do
          {ip, port, transport} ->
            Logger.debug(
              "Session.Worker: connection to #{:inet.ntoa(ip)}:#{port} over #{transport} failed (#{inspect(reason)})"
            )

          nil ->
            :ok
        end

        {:noreply, %{state | pending: Map.delete(state.pending, pid)}}

      peer_id ->
        {:noreply, remove_peer(state, peer_id, pid)}
    end
  end

  ## handle_cast — peer lifecycle, data transfer, magnet metadata resolution

  @impl true
  def handle_cast({:peer_connected, pid, peer_id}, state) do
    state = %{
      state
      | peers: Map.put(state.peers, peer_id, pid),
        peer_info: Map.put(state.peer_info, pid, peer_id),
        peer_addresses: put_address(state.peer_addresses, peer_id, Map.get(state.pending, pid)),
        pending: Map.delete(state.pending, pid),
        choke_state: Map.put(state.choke_state, peer_id, %{interested: false, download_rate: 0})
    }

    if state.meta_info, do: PeerConnection.send_message(pid, :interested)
    {:noreply, state}
  end

  def handle_cast({:peer_disconnected, peer_id, _reason}, state) do
    {:noreply, remove_peer(state, peer_id, Map.get(state.peers, peer_id))}
  end

  def handle_cast({:peer_interested, peer_id}, state) do
    {:noreply, put_interested(state, peer_id, true)}
  end

  def handle_cast({:peer_not_interested, peer_id}, state) do
    {:noreply, put_interested(state, peer_id, false)}
  end

  def handle_cast({:peer_unchoked, peer_id}, state) do
    {:noreply,
     try_request_blocks(%{state | unchoked_by: MapSet.put(state.unchoked_by, peer_id)}, peer_id)}
  end

  def handle_cast({:peer_choked, peer_id}, state) do
    {:noreply, %{state | unchoked_by: MapSet.delete(state.unchoked_by, peer_id)}}
  end

  def handle_cast({:peer_bitfield, peer_id, bitfield}, state) do
    state =
      if state.picker && bitfield?(bitfield, state) do
        update(state, :picker, &PiecePicker.set_peer_bitfield(&1, peer_id, bitfield))
      else
        state
      end

    {:noreply, try_request_blocks(state, peer_id)}
  end

  def handle_cast({:peer_have, peer_id, index}, state) do
    state =
      if state.picker,
        do: update(state, :picker, &PiecePicker.mark_have(&1, peer_id, index)),
        else: state

    {:noreply, try_request_blocks(state, peer_id)}
  end

  def handle_cast({:block_received, peer_id, index, begin, data}, %{meta_info: nil} = state) do
    # Shouldn't happen (blocks only flow once metadata/picker exist), but
    # don't crash the session over a misbehaving/racy peer.
    _ = {peer_id, index, begin, data}
    {:noreply, state}
  end

  def handle_cast({:block_received, peer_id, index, begin, data}, state) do
    :ok = Storage.write_block(state.storage_pid, index, begin, data)

    state =
      state
      |> update(:picker, &PiecePicker.mark_received(&1, index, begin))
      |> Map.update!(:downloaded, &(&1 + byte_size(data)))
      |> maybe_complete_piece(index)
      |> try_request_blocks(peer_id)

    {:noreply, state}
  end

  def handle_cast(
        {:peer_supports_ut_metadata, peer_id},
        %{meta_info: nil, metadata_requested_from: nil} = state
      ) do
    case Map.get(state.peers, peer_id) do
      nil ->
        {:noreply, state}

      pid ->
        PeerConnection.request_metadata_piece(pid, 0)
        {:noreply, %{state | metadata_requested_from: peer_id}}
    end
  end

  def handle_cast({:peer_supports_ut_metadata, _peer_id}, state), do: {:noreply, state}

  def handle_cast(
        {:metadata_piece_received, peer_id, piece_index, total_size, chunk},
        %{meta_info: nil} = state
      ) do
    state = %{
      state
      | metadata_total_size: total_size,
        metadata_chunks: Map.put(state.metadata_chunks, piece_index, chunk)
    }

    received = state.metadata_chunks |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if received >= total_size do
      finalize_metadata(state, total_size)
    else
      next_index = piece_index + 1

      if pid = Map.get(state.peers, peer_id),
        do: PeerConnection.request_metadata_piece(pid, next_index)

      {:noreply, state}
    end
  end

  def handle_cast({:metadata_piece_received, _peer_id, _index, _total, _chunk}, state),
    do: {:noreply, state}

  ## Announce loop internals

  defp do_announce(state) do
    case current_tracker(state) do
      nil ->
        state

      tracker_url ->
        params = %{
          info_hash: state.info_hash,
          peer_id: state.our_peer_id,
          port: listen_port(),
          uploaded: state.uploaded,
          downloaded: state.downloaded,
          left: left_bytes(state),
          event: if(state.announced?, do: nil, else: :started)
        }

        case TrackerClient.dispatch(tracker_url, params, []) do
          {:ok, %{interval: interval} = result} ->
            Logger.debug(
              "Session.Worker: #{tracker_url} returned #{length(result.peers)} peer(s) " <>
                "(seeders=#{inspect(result.seeders)}, leechers=#{inspect(result.leechers)})"
            )

            state = %{
              state
              | known_peers: MapSet.union(state.known_peers, MapSet.new(result.peers))
            }

            state = connect_to_peers(state, result.peers)
            schedule_announce(max(interval, @min_announce_interval))

            %{
              state
              | announced?: true,
                tracker_seeders: result.seeders,
                tracker_leechers: result.leechers
            }

          {:error, reason} ->
            Logger.warning(
              "Session.Worker: announce to #{tracker_url} failed (#{inspect(reason)}), trying next tracker"
            )

            # Fall back to the next tracker in the (flattened, tier-ordered)
            # list rather than retrying the same one forever — a single
            # unreachable/dead tracker must not permanently stall the
            # session when the torrent lists working alternatives.
            schedule_announce(5)
            %{state | tracker_index: state.tracker_index + 1}
        end
    end
  end

  # BEP 12 announce-list, flattened into one ordered fallback list (tier
  # order preserved). `tracker_index` only ever increases and wraps via
  # `rem/2` here — it's not reset on success, so a subsequent scheduled
  # re-announce keeps using whichever tracker most recently worked instead
  # of hopping back to a possibly-dead primary.
  defp current_tracker(%{trackers: []}), do: nil

  defp current_tracker(state) do
    flat = List.flatten(state.trackers)
    Enum.at(flat, rem(state.tracker_index, length(flat)))
  end

  defp left_bytes(%{meta_info: nil}), do: 0
  defp left_bytes(state), do: max(state.meta_info.total_length - state.downloaded, 0)

  defp listen_port do
    Application.get_env(:flux, :torrent, [])[:listen_port] || 51413
  end

  defp schedule_announce(seconds), do: Process.send_after(self(), :announce, seconds * 1000)
  defp schedule_choke_tick, do: Process.send_after(self(), :choke_tick, @choke_interval)

  defp schedule_peer_fill_tick,
    do: Process.send_after(self(), :peer_fill_tick, @peer_fill_interval)

  defp schedule_dht_tick(delay_ms \\ @dht_tick_interval),
    do: Process.send_after(self(), :dht_tick, delay_ms)

  # Only one lookup in flight at a time — `dht_lookup_pid` is cleared by the
  # :DOWN handler once it exits (normally or otherwise), letting the next
  # tick start a fresh one.
  defp start_dht_lookup(%{dht_lookup_pid: pid} = state) when is_pid(pid), do: state

  defp start_dht_lookup(state) do
    info_hash = state.info_hash
    parent = self()

    {pid, _ref} =
      spawn_monitor(fn -> send(parent, {:dht_peers_result, self(), Dht.get_peers(info_hash)}) end)

    %{state | dht_lookup_pid: pid}
  end

  # `peer_list` is plain `{ip, port}` addresses (from trackers/DHT, which
  # know nothing about transport) — each expands to two independent
  # candidates here, one per transport, since a TCP attempt to an address
  # failing tells us nothing about whether uTP to that same address would
  # work (and vice versa; this is the entire point of adding uTP: some
  # real-world peers are only reachable over one or the other).
  defp connect_to_peers(state, peer_list) do
    active = MapSet.new(Map.values(state.pending) ++ Map.values(state.peer_addresses))
    slots = @max_peers - map_size(state.peers) - map_size(state.pending)

    candidates =
      for {ip, port} <- peer_list,
          transport <- [:tcp, :utp],
          candidate = {ip, port, transport},
          not MapSet.member?(active, candidate),
          do: candidate

    # Never-tried candidates first, previously-failed ones only to fill any
    # remaining slots — otherwise a handful of addresses that failed once
    # immediately become eligible again (nothing else marks them as
    # recently-failed) and, since candidate ordering is otherwise stable,
    # just keep winning the same slots forever while the rest of a large
    # swarm (where most real connect failures come from ordinary NAT'd
    # peers, not anything wrong on our end) never gets a first attempt.
    {untried, previously_tried} =
      Enum.split_with(candidates, &(not MapSet.member?(state.tried_peers, &1)))

    (untried ++ previously_tried)
    |> Enum.take(max(slots, 0))
    |> Enum.reduce(state, fn {ip, port, transport}, acc ->
      start_peer_connection(acc, ip, port, transport)
    end)
  end

  defp start_peer_connection(state, ip, port, transport) do
    state = %{state | tried_peers: MapSet.put(state.tried_peers, {ip, port, transport})}

    opts = [
      session_pid: self(),
      info_hash: state.info_hash,
      our_peer_id: state.our_peer_id,
      storage_pid: state.storage_pid,
      piece_count: piece_count(state),
      our_bitfield: our_bitfield_wire(state),
      raw_info_bytes: state.meta_info && state.meta_info.raw_info_bytes,
      metadata_size: state.meta_info && byte_size(state.meta_info.raw_info_bytes),
      transport: transport
    ]

    child_spec = %{
      id: {PeerConnection, ip, port, transport, System.unique_integer()},
      start: {PeerConnection, :start_link_outbound, [ip, port, opts]},
      restart: :temporary
    }

    result =
      DynamicSupervisor.start_child(
        Flux.Torrent.Session.peer_sup_name(state.download_id),
        child_spec
      )

    case result do
      {:ok, pid} ->
        Process.monitor(pid)
        %{state | pending: Map.put(state.pending, pid, {ip, port, transport})}

      {:error, reason} ->
        # The connect itself is async (handled by the started process via
        # handle_continue) and reported later via :DOWN if it fails — this
        # branch only fires for a supervisor-level failure to even start
        # the child process (e.g. hitting :max_children).
        Logger.debug(
          "Session.Worker: could not start a connection process for #{:inet.ntoa(ip)}:#{port} over #{transport} (#{inspect(reason)})"
        )

        state
    end
  end

  defp piece_count(%{meta_info: nil}), do: nil
  defp piece_count(state), do: length(state.meta_info.pieces)

  defp our_bitfield_wire(%{our_bitfield: nil}), do: nil
  defp our_bitfield_wire(state), do: Bitfield.to_wire(state.our_bitfield)

  ## Peer lifecycle internals

  defp put_interested(state, peer_id, interested?) do
    update(state, :choke_state, fn choke_state ->
      Map.update(choke_state, peer_id, %{interested: interested?, download_rate: 0}, fn s ->
        %{s | interested: interested?}
      end)
    end)
  end

  defp bitfield?(bitfield, state),
    do: bit_size(bitfield) == bit_size(Bitfield.new(piece_count(state)))

  defp try_request_blocks(%{picker: nil} = state, _peer_id), do: state

  defp try_request_blocks(state, peer_id) do
    if MapSet.member?(state.unchoked_by, peer_id) do
      case PiecePicker.next_request(state.picker, peer_id) do
        {:ok, {index, begin, length}} ->
          pid = Map.get(state.peers, peer_id)
          if pid, do: PeerConnection.send_message(pid, {:request, index, begin, length})
          update(state, :picker, &PiecePicker.mark_requested(&1, index, begin, peer_id))

        :none ->
          state
      end
    else
      state
    end
  end

  defp remove_peer(state, peer_id, pid) do
    %{
      state
      | peers: Map.delete(state.peers, peer_id),
        peer_info: if(pid, do: Map.delete(state.peer_info, pid), else: state.peer_info),
        peer_addresses: Map.delete(state.peer_addresses, peer_id),
        choke_state: Map.delete(state.choke_state, peer_id),
        unchoked_by: MapSet.delete(state.unchoked_by, peer_id),
        picker: state.picker && PiecePicker.release_peer(state.picker, peer_id)
    }
  end

  defp put_address(addresses, _peer_id, nil), do: addresses
  defp put_address(addresses, peer_id, address), do: Map.put(addresses, peer_id, address)

  defp update(state, key, fun), do: Map.update!(state, key, fun)

  ## Data transfer internals

  defp maybe_complete_piece(state, index) do
    if Bitfield.has?(state.our_bitfield, index) do
      state
    else
      case Storage.verify_piece(state.storage_pid, index) do
        :ok ->
          our_bitfield = Bitfield.set(state.our_bitfield, index)
          broadcast_have(state, index)
          persist_progress(state, our_bitfield)

          %{
            state
            | our_bitfield: our_bitfield,
              picker: PiecePicker.set_our_bitfield(state.picker, our_bitfield)
          }

        _ ->
          state
      end
    end
  end

  defp broadcast_have(state, index) do
    for {_id, pid} <- state.peers, do: PeerConnection.send_message(pid, {:have, index})
  end

  defp persist_progress(state, our_bitfield) do
    download = Downloads.get_download!(state.download_id)

    Downloads.update_progress(
      download,
      bytes_for_bitfield(our_bitfield, state.meta_info),
      Bitfield.to_wire(our_bitfield)
    )
  end

  defp bytes_for_bitfield(bitfield, meta_info) do
    piece_count = length(meta_info.pieces)

    Enum.reduce(0..(piece_count - 1), 0, fn index, acc ->
      if Bitfield.has?(bitfield, index) do
        size =
          if index == piece_count - 1,
            do: meta_info.total_length - index * meta_info.piece_length,
            else: meta_info.piece_length

        acc + size
      else
        acc
      end
    end)
  end

  ## BEP 9/10 — magnet metadata resolution internals

  defp finalize_metadata(state, total_size) do
    piece_count = div(total_size + @block_size - 1, @block_size)

    assembled =
      for i <- 0..(piece_count - 1), into: <<>>, do: Map.fetch!(state.metadata_chunks, i)

    case MetaInfo.parse_info_dict(assembled, state.trackers) do
      {:ok, meta_info} ->
        if meta_info.info_hash == state.info_hash do
          download = Downloads.get_download!(state.download_id)

          {:ok, download} =
            Downloads.update_download(download, %{
              name: meta_info.name,
              total_length: meta_info.total_length,
              piece_length: meta_info.piece_length,
              info_dict: meta_info.raw_info_bytes
            })

          case start_with_metadata(%{state | metadata_chunks: %{}}, meta_info, download) do
            {:ok, state2} -> {:noreply, state2}
            :ignore -> {:stop, :normal, state}
          end
        else
          {:noreply,
           %{state | metadata_chunks: %{}, metadata_total_size: nil, metadata_requested_from: nil}}
        end

      {:error, _reason} ->
        {:noreply,
         %{state | metadata_chunks: %{}, metadata_total_size: nil, metadata_requested_from: nil}}
    end
  end
end
