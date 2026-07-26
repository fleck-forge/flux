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
    PeerConnection
  }

  @block_size 16_384
  @max_peers 30
  @choke_interval 10_000
  @min_announce_interval 30

  defstruct [
    :download_id,
    :info_hash,
    :our_peer_id,
    :save_path,
    :meta_info,
    :storage_pid,
    trackers: [],
    peers: %{},
    peer_info: %{},
    pending: %{},
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
    metadata_requested_from: nil
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

      trackers == [] ->
        Downloads.mark_failed(
          download,
          "no trackers in magnet link and DHT is not supported — add a magnet link with tracker (&tr=) parameters"
        )

        :ignore

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
          state: final_state
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

      schedule_choke_tick()
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.get(state.peer_info, pid) do
      nil -> {:noreply, %{state | pending: Map.delete(state.pending, pid)}}
      peer_id -> {:noreply, remove_peer(state, peer_id, pid)}
    end
  end

  ## handle_cast — peer lifecycle, data transfer, magnet metadata resolution

  @impl true
  def handle_cast({:peer_connected, pid, peer_id}, state) do
    state = %{
      state
      | peers: Map.put(state.peers, peer_id, pid),
        peer_info: Map.put(state.peer_info, pid, peer_id),
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
            state = connect_to_peers(state, result.peers)
            schedule_announce(max(interval, @min_announce_interval))
            %{state | announced?: true}

          {:error, reason} ->
            Logger.warning("Session.Worker: tracker announce failed (#{inspect(reason)})")
            schedule_announce(60)
            state
        end
    end
  end

  defp current_tracker(%{trackers: []}), do: nil
  defp current_tracker(%{trackers: [tier | _]}), do: List.first(tier)

  defp left_bytes(%{meta_info: nil}), do: 0
  defp left_bytes(state), do: max(state.meta_info.total_length - state.downloaded, 0)

  defp listen_port do
    Application.get_env(:flux, :torrent, [])[:listen_port] || 51413
  end

  defp schedule_announce(seconds), do: Process.send_after(self(), :announce, seconds * 1000)
  defp schedule_choke_tick, do: Process.send_after(self(), :choke_tick, @choke_interval)

  defp connect_to_peers(state, peer_list) do
    already_connecting = MapSet.new(Map.values(state.pending))
    slots = @max_peers - map_size(state.peers) - map_size(state.pending)

    peer_list
    |> Enum.reject(fn addr -> MapSet.member?(already_connecting, addr) end)
    |> Enum.take(max(slots, 0))
    |> Enum.reduce(state, fn {ip, port}, acc -> start_peer_connection(acc, ip, port) end)
  end

  defp start_peer_connection(state, ip, port) do
    opts = [
      session_pid: self(),
      info_hash: state.info_hash,
      our_peer_id: state.our_peer_id,
      storage_pid: state.storage_pid,
      piece_count: piece_count(state),
      our_bitfield: our_bitfield_wire(state),
      raw_info_bytes: state.meta_info && state.meta_info.raw_info_bytes,
      metadata_size: state.meta_info && byte_size(state.meta_info.raw_info_bytes)
    ]

    child_spec = %{
      id: {PeerConnection, ip, port, System.unique_integer()},
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
        %{state | pending: Map.put(state.pending, pid, {ip, port})}

      _ ->
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
        choke_state: Map.delete(state.choke_state, peer_id),
        unchoked_by: MapSet.delete(state.unchoked_by, peer_id),
        picker: state.picker && PiecePicker.release_peer(state.picker, peer_id)
    }
  end

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
