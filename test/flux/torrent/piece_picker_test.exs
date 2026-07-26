defmodule Flux.Torrent.PiecePickerTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.{PiecePicker, Bitfield}

  # 3 pieces, piece_length 32, total_length 80 (last piece is 16 bytes ->
  # exactly one 16KiB-equivalent block for test purposes, using a small
  # block-independent piece_length so blocks_for produces >1 block/piece).
  defp new_picker do
    PiecePicker.new(3, 32, 80)
  end

  test "next_request/2 returns :none when the peer has nothing we need" do
    picker = new_picker() |> PiecePicker.set_peer_bitfield("peer1", Bitfield.new(3))
    assert PiecePicker.next_request(picker, "peer1") == :none
  end

  test "next_request/2 returns :none for an unknown peer" do
    picker = new_picker()
    assert PiecePicker.next_request(picker, "unknown") == :none
  end

  test "next_request/2 picks a block from a piece the peer has" do
    peer_bf = Bitfield.new(3) |> Bitfield.set(1)
    picker = new_picker() |> PiecePicker.set_peer_bitfield("peer1", peer_bf)

    assert {:ok, {1, 0, _len}} = PiecePicker.next_request(picker, "peer1")
  end

  test "next_request/2 does not re-offer an in-flight block to the SAME peer outside endgame" do
    # 6 missing pieces keeps us above the endgame threshold (5).
    picker = PiecePicker.new(6, 16, 96)
    peer_bf = Bitfield.new(6) |> Bitfield.set(0)
    picker = PiecePicker.set_peer_bitfield(picker, "peer1", peer_bf)

    {:ok, {0, 0, len}} = PiecePicker.next_request(picker, "peer1")
    picker = PiecePicker.mark_requested(picker, 0, 0, "peer1")

    # Only one 16-byte block in piece 0 (piece_length == block_size here),
    # and peer1 has nothing else -> nothing left to offer them.
    assert len == 16
    assert PiecePicker.next_request(picker, "peer1") == :none
  end

  test "mark_received/3 frees a block back up for requesting" do
    peer_bf = Bitfield.new(3) |> Bitfield.set(0)
    picker = new_picker() |> PiecePicker.set_peer_bitfield("peer1", peer_bf)

    picker = PiecePicker.mark_requested(picker, 0, 0, "peer1")
    picker = PiecePicker.mark_received(picker, 0, 0)

    assert {:ok, {0, 0, _}} = PiecePicker.next_request(picker, "peer1")
  end

  test "set_our_bitfield/2 removes pieces we already have from candidates" do
    peer_bf = Bitfield.new(3) |> Bitfield.set(0) |> Bitfield.set(1)
    our_bf = Bitfield.new(3) |> Bitfield.set(0)

    picker =
      new_picker()
      |> PiecePicker.set_peer_bitfield("peer1", peer_bf)
      |> PiecePicker.set_our_bitfield(our_bf)

    assert {:ok, {1, _begin, _len}} = PiecePicker.next_request(picker, "peer1")
  end

  test "mark_have/3 adds a single piece to a peer's availability" do
    picker = new_picker() |> PiecePicker.mark_have("peer1", 2)
    assert {:ok, {2, _begin, _len}} = PiecePicker.next_request(picker, "peer1")
  end

  test "release_peer/2 clears their availability and in-flight requests" do
    peer_bf = Bitfield.new(3) |> Bitfield.set(0)

    picker =
      new_picker()
      |> PiecePicker.set_peer_bitfield("peer1", peer_bf)
      |> PiecePicker.mark_requested(0, 0, "peer1")
      |> PiecePicker.release_peer("peer1")

    assert PiecePicker.next_request(picker, "peer1") == :none
  end

  describe "endgame behavior" do
    test "allows a duplicate request to a different peer once few pieces remain" do
      # 1 piece total (below/at the endgame threshold of 5).
      picker = PiecePicker.new(1, 32, 32)
      peer_bf = Bitfield.new(1) |> Bitfield.set(0)

      picker =
        picker
        |> PiecePicker.set_peer_bitfield("peer1", peer_bf)
        |> PiecePicker.set_peer_bitfield("peer2", peer_bf)

      {:ok, block} = PiecePicker.next_request(picker, "peer1")
      picker = PiecePicker.mark_requested(picker, elem(block, 0), elem(block, 1), "peer1")

      # peer1 already has this block in flight -> not offered again to peer1...
      assert PiecePicker.next_request(picker, "peer1") == :none
      # ...but peer2 can still pick it up as an endgame duplicate.
      assert {:ok, ^block} = PiecePicker.next_request(picker, "peer2")
    end
  end
end
