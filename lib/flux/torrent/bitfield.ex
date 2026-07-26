defmodule Flux.Torrent.Bitfield do
  @moduledoc """
  Piece-availability bitmap helpers.

  Represented as an Erlang bitstring, MSB-first per byte, padded to a whole
  number of bytes — this is exactly the BEP 3 wire `bitfield` message format,
  so `to_wire/1`/`from_wire/2` are no-ops beyond validating padding.
  """

  @type t :: bitstring()

  @doc "Builds an all-zero bitfield sized for `piece_count` pieces."
  @spec new(non_neg_integer()) :: t()
  def new(piece_count) when piece_count >= 0 do
    <<0::size(byte_count(piece_count) * 8)>>
  end

  @doc "Returns a copy of `bitfield` with `index` marked present."
  @spec set(t(), non_neg_integer()) :: t()
  def set(bitfield, index) do
    <<before::size(index), _bit::1, rest::bitstring>> = bitfield
    <<before::size(index), 1::1, rest::bitstring>>
  end

  @doc "Whether piece `index` is marked present."
  @spec has?(t(), non_neg_integer()) :: boolean()
  def has?(bitfield, index) when index >= 0 do
    case bitfield do
      <<_::size(index), bit::1, _::bitstring>> -> bit == 1
      _ -> false
    end
  end

  @doc "Number of pieces marked present."
  @spec count_set(t()) :: non_neg_integer()
  def count_set(bitfield) do
    for(<<bit::1 <- bitfield>>, do: bit) |> Enum.sum()
  end

  @doc "Whether all of the first `piece_count` bits are set."
  @spec complete?(t(), non_neg_integer()) :: boolean()
  def complete?(bitfield, piece_count) do
    missing_indices(bitfield, piece_count) == []
  end

  @doc "Indices (0-based) among the first `piece_count` pieces that are NOT set."
  @spec missing_indices(t(), non_neg_integer()) :: [non_neg_integer()]
  def missing_indices(bitfield, piece_count) do
    for index <- 0..(piece_count - 1), not has?(bitfield, index), do: index
  end

  @doc "The raw wire-format bytes for this bitfield (identity — already wire shaped)."
  @spec to_wire(t()) :: binary()
  def to_wire(bitfield) do
    pad = rem(8 - rem(bit_size(bitfield), 8), 8)
    <<bitfield::bitstring, 0::size(pad)>>
  end

  @doc """
  Parses a wire-format bitfield binary for a torrent with `piece_count`
  pieces. Rejects a binary that's the wrong length for the expected number
  of (padded-to-byte) pieces, or whose spare padding bits aren't zero.
  """
  @spec from_wire(binary(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def from_wire(binary, piece_count) do
    expected_bytes = byte_count(piece_count)

    with true <- byte_size(binary) == expected_bytes || {:error, :wrong_length},
         true <- padding_zero?(binary, piece_count) || {:error, :nonzero_padding} do
      <<bits::size(piece_count), _padding::bitstring>> = binary
      {:ok, <<bits::size(piece_count)>>}
    end
  end

  defp padding_zero?(binary, piece_count) do
    padding_bits = byte_count(piece_count) * 8 - piece_count

    case binary do
      <<_::size(piece_count), padding::size(padding_bits)>> -> padding == 0
      _ -> false
    end
  end

  defp byte_count(piece_count), do: div(piece_count + 7, 8)
end
