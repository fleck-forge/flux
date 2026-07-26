defmodule Flux.Torrent.BitfieldTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Bitfield

  test "new/1 creates an all-zero, byte-padded bitfield" do
    bf = Bitfield.new(10)
    assert bit_size(bf) == 16
    assert Bitfield.count_set(bf) == 0
  end

  test "set/2 and has?/2" do
    bf = Bitfield.new(10)
    refute Bitfield.has?(bf, 3)
    bf = Bitfield.set(bf, 3)
    assert Bitfield.has?(bf, 3)
    refute Bitfield.has?(bf, 4)
  end

  test "count_set/1 counts all set bits" do
    bf = Bitfield.new(10) |> Bitfield.set(0) |> Bitfield.set(9)
    assert Bitfield.count_set(bf) == 2
  end

  test "missing_indices/2 and complete?/2" do
    bf = Bitfield.new(3) |> Bitfield.set(0) |> Bitfield.set(2)
    assert Bitfield.missing_indices(bf, 3) == [1]
    refute Bitfield.complete?(bf, 3)

    full = bf |> Bitfield.set(1)
    assert Bitfield.missing_indices(full, 3) == []
    assert Bitfield.complete?(full, 3)
  end

  test "to_wire/1 pads to a whole byte, MSB-first" do
    bf = Bitfield.new(3) |> Bitfield.set(0)
    wire = Bitfield.to_wire(bf)
    assert wire == <<0b10000000>>
  end

  test "from_wire/2 round-trips with to_wire/1" do
    bf = Bitfield.new(10) |> Bitfield.set(0) |> Bitfield.set(9)
    wire = Bitfield.to_wire(bf)
    assert {:ok, decoded} = Bitfield.from_wire(wire, 10)
    assert Bitfield.has?(decoded, 0)
    assert Bitfield.has?(decoded, 9)
    assert Bitfield.count_set(decoded) == 2
  end

  test "from_wire/2 rejects wrong length" do
    assert {:error, :wrong_length} = Bitfield.from_wire(<<0, 0>>, 3)
  end

  test "from_wire/2 rejects nonzero padding bits" do
    # 3 pieces -> 1 byte, top 3 bits are real, bottom 5 must be zero.
    assert {:error, :nonzero_padding} = Bitfield.from_wire(<<0b00000001>>, 3)
  end

  test "handles non-byte-aligned piece counts at boundaries" do
    bf = Bitfield.new(9) |> Bitfield.set(8)
    assert Bitfield.has?(bf, 8)
    assert Bitfield.complete?(bf, 9) == false
    wire = Bitfield.to_wire(bf)
    assert bit_size(wire) == 16
  end
end
