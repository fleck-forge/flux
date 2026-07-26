defmodule Flux.Torrent.PiecePicker do
  @moduledoc """
  Decides which block to request next. v1 behavior: sequential piece order
  (not rarest-first), with classic "endgame" duplicate requests once few
  pieces remain.

  This is an explicit swap seam — everything a smarter (e.g. rarest-first)
  picker would need is already tracked here (`peer_bitfields`, `requested`),
  so a future replacement only needs to change `next_request/2`'s piece
  ordering, not any caller.
  """

  alias Flux.Torrent.Bitfield

  @block_size 16_384
  @endgame_threshold 5

  defstruct [
    :piece_count,
    :piece_length,
    :total_length,
    :our_bitfield,
    peer_bitfields: %{},
    requested: %{}
  ]

  @type t :: %__MODULE__{}

  def new(piece_count, piece_length, total_length, our_bitfield \\ nil) do
    %__MODULE__{
      piece_count: piece_count,
      piece_length: piece_length,
      total_length: total_length,
      our_bitfield: our_bitfield || Bitfield.new(piece_count)
    }
  end

  @doc "Updates the pieces we have (call after a piece is verified on disk)."
  def set_our_bitfield(state, bitfield), do: %{state | our_bitfield: bitfield}

  @doc "Replaces a peer's full advertised bitfield (on receiving their `bitfield` message)."
  def set_peer_bitfield(state, peer_id, bitfield) do
    %{state | peer_bitfields: Map.put(state.peer_bitfields, peer_id, bitfield)}
  end

  @doc "Records a single `have` announcement from a peer."
  def mark_have(state, peer_id, index) do
    bf = Map.get(state.peer_bitfields, peer_id, Bitfield.new(state.piece_count))
    %{state | peer_bitfields: Map.put(state.peer_bitfields, peer_id, Bitfield.set(bf, index))}
  end

  @doc "Forgets a disconnected peer's availability and releases their in-flight requests."
  def release_peer(state, peer_id) do
    peer_bitfields = Map.delete(state.peer_bitfields, peer_id)

    requested =
      state.requested
      |> Enum.map(fn {block, peers} -> {block, MapSet.delete(peers, peer_id)} end)
      |> Enum.reject(fn {_block, peers} -> MapSet.size(peers) == 0 end)
      |> Map.new()

    %{state | peer_bitfields: peer_bitfields, requested: requested}
  end

  @doc "Records that `peer_id` has been asked for block `{index, begin}`."
  def mark_requested(state, index, begin, peer_id) do
    key = {index, begin}
    peers = Map.get(state.requested, key, MapSet.new())
    %{state | requested: Map.put(state.requested, key, MapSet.put(peers, peer_id))}
  end

  @doc "Clears in-flight tracking for a block once any peer's data for it has arrived."
  def mark_received(state, index, begin) do
    %{state | requested: Map.delete(state.requested, {index, begin})}
  end

  @doc """
  Picks the next `{index, begin, length}` block to request from `peer_id`,
  or `:none` if `peer_id` has nothing we currently need (or everything
  needed from them is already requested and we're not yet in endgame).
  """
  @spec next_request(t(), term()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), pos_integer()}} | :none
  def next_request(state, peer_id) do
    case Map.get(state.peer_bitfields, peer_id) do
      nil ->
        :none

      peer_bitfield ->
        missing = Bitfield.missing_indices(state.our_bitfield, state.piece_count)
        candidates = Enum.filter(missing, &Bitfield.has?(peer_bitfield, &1))

        case find_block(state, candidates, fn key ->
               not Map.has_key?(state.requested, key)
             end) do
          {:ok, block} ->
            {:ok, block}

          :none ->
            if length(missing) <= @endgame_threshold do
              find_block(state, candidates, fn key ->
                peer_id not in Map.get(state.requested, key, MapSet.new())
              end)
            else
              :none
            end
        end
    end
  end

  defp find_block(state, piece_indices, accept?) do
    Enum.find_value(piece_indices, :none, fn index ->
      Enum.find_value(blocks_for(state, index), fn {begin, len} ->
        if accept?.({index, begin}), do: {:ok, {index, begin, len}}
      end)
    end)
  end

  defp blocks_for(state, index) do
    size = piece_size(state, index)

    if size <= 0 do
      []
    else
      for begin <- Stream.iterate(0, &(&1 + @block_size)) |> Enum.take_while(&(&1 < size)) do
        {begin, min(@block_size, size - begin)}
      end
    end
  end

  defp piece_size(state, index) do
    last_index = state.piece_count - 1

    if index == last_index do
      state.total_length - index * state.piece_length
    else
      state.piece_length
    end
  end
end
