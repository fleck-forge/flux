defmodule Flux.Torrent.WireProtocol do
  @moduledoc """
  Pure encode/decode for the BitTorrent peer wire protocol (BEP 3), the
  extension protocol handshake (BEP 10), and ut_metadata (BEP 9) messages.
  No process state — `Flux.Torrent.PeerConnection` owns the socket and
  buffering; this module only turns bytes into terms and back.

  All multi-byte integers are big-endian, per BEP 3.
  """

  alias Flux.Bencode

  @protocol_name "BitTorrent protocol"
  @handshake_size 1 + byte_size(@protocol_name) + 8 + 20 + 20
  @block_size 16_384

  @message_ids %{
    choke: 0,
    unchoke: 1,
    interested: 2,
    not_interested: 3,
    have: 4,
    bitfield: 5,
    request: 6,
    piece: 7,
    cancel: 8,
    port: 9,
    extended: 20
  }

  ## Handshake

  @doc "Encodes the fixed 68-byte BEP 3 handshake."
  @spec encode_handshake(binary(), binary(), binary()) :: binary()
  def encode_handshake(info_hash, peer_id, reserved \\ <<0, 0, 0, 0, 0, 0, 0, 0>>)
      when byte_size(info_hash) == 20 and byte_size(peer_id) == 20 and byte_size(reserved) == 8 do
    pstr = @protocol_name
    <<byte_size(pstr), pstr::binary, reserved::binary, info_hash::binary, peer_id::binary>>
  end

  @doc "Decodes a handshake from the head of `binary`, returning any remainder."
  @spec decode_handshake(binary()) ::
          {:ok, %{reserved: binary(), info_hash: binary(), peer_id: binary()}, binary()}
          | {:incomplete, binary()}
          | {:error, term()}
  def decode_handshake(binary) when byte_size(binary) < @handshake_size do
    {:incomplete, binary}
  end

  def decode_handshake(binary) do
    pstr_len = byte_size(@protocol_name)

    case binary do
      <<^pstr_len, pstr::binary-size(pstr_len), reserved::binary-size(8), info_hash::binary-size(20),
        peer_id::binary-size(20), rest::binary>>
      when pstr == @protocol_name ->
        {:ok, %{reserved: reserved, info_hash: info_hash, peer_id: peer_id}, rest}

      _ ->
        {:error, :bad_protocol}
    end
  end

  @doc "Sets the BEP 10 extension-protocol support bit in a reserved-bytes field."
  @spec set_extension_bit(binary()) :: binary()
  def set_extension_bit(<<b0, b1, b2, b3, b4, b5, b6, b7>>) do
    <<b0, b1, b2, b3, b4, Bitwise.bor(b5, 0x10), b6, b7>>
  end

  @doc "Whether the peer's reserved bytes advertise BEP 10 extension protocol support."
  @spec extension_supported?(binary()) :: boolean()
  def extension_supported?(<<_::binary-size(5), b5, _::binary-size(2)>>) do
    Bitwise.band(b5, 0x10) != 0
  end

  ## Standard messages

  @doc "Encodes a standard wire message, framed as `<<len::32, id::8, payload>>`."
  @spec encode_message(term()) :: binary()
  def encode_message(:keep_alive), do: <<0::32>>
  def encode_message(:choke), do: frame(@message_ids.choke, <<>>)
  def encode_message(:unchoke), do: frame(@message_ids.unchoke, <<>>)
  def encode_message(:interested), do: frame(@message_ids.interested, <<>>)
  def encode_message(:not_interested), do: frame(@message_ids.not_interested, <<>>)
  def encode_message({:have, index}), do: frame(@message_ids.have, <<index::32>>)
  def encode_message({:bitfield, bits}), do: frame(@message_ids.bitfield, bits)

  def encode_message({:request, index, begin, length}) do
    frame(@message_ids.request, <<index::32, begin::32, length::32>>)
  end

  def encode_message({:piece, index, begin, block}) do
    frame(@message_ids.piece, <<index::32, begin::32, block::binary>>)
  end

  def encode_message({:cancel, index, begin, length}) do
    frame(@message_ids.cancel, <<index::32, begin::32, length::32>>)
  end

  def encode_message({:port, port}), do: frame(@message_ids.port, <<port::16>>)

  defp frame(id, payload), do: <<byte_size(payload) + 1::32, id, payload::binary>>

  @doc """
  Decodes exactly one framed message from the head of `binary`.

  Returns `{:incomplete, binary}` (the *original* input, unconsumed) when
  there isn't yet a full frame available, so callers can accumulate more
  bytes from the socket and retry without losing data.
  """
  @spec decode_message(binary()) :: {:ok, term(), binary()} | {:incomplete, binary()} | {:error, term()}
  def decode_message(binary) when byte_size(binary) < 4, do: {:incomplete, binary}

  def decode_message(<<0::32, rest::binary>>), do: {:ok, :keep_alive, rest}

  def decode_message(<<len::32, rest::binary>> = binary) do
    if byte_size(rest) < len do
      {:incomplete, binary}
    else
      <<payload::binary-size(len), remainder::binary>> = rest
      decode_payload(payload, remainder)
    end
  end

  defp decode_payload(<<id, body::binary>>, rest) do
    case id do
      0 -> {:ok, :choke, rest}
      1 -> {:ok, :unchoke, rest}
      2 -> {:ok, :interested, rest}
      3 -> {:ok, :not_interested, rest}
      4 -> decode_have(body, rest)
      5 -> {:ok, {:bitfield, body}, rest}
      6 -> decode_request(body, rest, :request)
      7 -> decode_piece(body, rest)
      8 -> decode_request(body, rest, :cancel)
      9 -> decode_port(body, rest)
      20 -> decode_extended_message(body, rest)
      other -> {:error, {:unknown_message_id, other}}
    end
  end

  defp decode_payload(<<>>, _rest), do: {:error, :empty_payload}

  defp decode_have(<<index::32>>, rest), do: {:ok, {:have, index}, rest}
  defp decode_have(_, _), do: {:error, :malformed_have}

  defp decode_request(<<index::32, begin::32, length::32>>, rest, tag) do
    {:ok, {tag, index, begin, length}, rest}
  end

  defp decode_request(_, _, _), do: {:error, :malformed_request}

  defp decode_piece(<<index::32, begin::32, block::binary>>, rest) do
    {:ok, {:piece, index, begin, block}, rest}
  end

  defp decode_port(<<port::16>>, rest), do: {:ok, {:port, port}, rest}
  defp decode_port(_, _), do: {:error, :malformed_port}

  defp decode_extended_message(<<ext_id, ext_payload::binary>>, rest) do
    {:ok, {:extended, ext_id, ext_payload}, rest}
  end

  defp decode_extended_message(<<>>, _rest), do: {:error, :malformed_extended}

  ## BEP 10 — extension protocol

  @doc "Encodes an id-20 (`extended`) message wrapping `ext_id` and `payload`."
  @spec encode_extended(non_neg_integer(), binary()) :: binary()
  def encode_extended(ext_id, payload) do
    frame(@message_ids.extended, <<ext_id, payload::binary>>)
  end

  @doc """
  Encodes the BEP 10 extended handshake (ext_id 0), advertising the local
  extension-id mapping (e.g. `%{"ut_metadata" => 1}`) and, if known, the
  torrent's `metadata_size` (so a peer that already has full metadata can
  serve ut_metadata to us).
  """
  @spec encode_extended_handshake(%{String.t() => non_neg_integer()}, non_neg_integer() | nil) ::
          binary()
  def encode_extended_handshake(supported_extensions, metadata_size \\ nil) do
    m_pairs = Enum.map(supported_extensions, fn {name, id} -> {name, id} end)

    dict =
      [{"m", m_pairs}] ++
        if metadata_size, do: [{"metadata_size", metadata_size}], else: []

    encode_extended(0, Bencode.encode(dict))
  end

  @doc "Decodes a BEP 10 extended handshake payload (the bytes after the ext_id byte)."
  @spec decode_extended_handshake(binary()) ::
          {:ok, %{extensions: %{String.t() => non_neg_integer()}, metadata_size: non_neg_integer() | nil}}
          | {:error, term()}
  def decode_extended_handshake(payload) do
    with {:ok, dict, _rest} <- Bencode.decode(payload) do
      m_pairs = dict_get(dict, "m") || []
      extensions = Map.new(m_pairs, fn {name, id} -> {name, id} end)
      {:ok, %{extensions: extensions, metadata_size: dict_get(dict, "metadata_size")}}
    end
  end

  ## BEP 9 — ut_metadata

  @doc "Encodes a ut_metadata `request` message for metadata piece `piece_index`."
  @spec encode_ut_metadata_request(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_ut_metadata_request(ext_id, piece_index) do
    dict = [{"msg_type", 0}, {"piece", piece_index}]
    encode_extended(ext_id, Bencode.encode(dict))
  end

  @doc """
  Encodes a ut_metadata `data` message for metadata piece `piece_index`,
  slicing the exact original bytes of `raw_info_bytes` — no re-encoding of
  the info dict is involved, since the requesting peer will SHA-1-verify
  the reassembled whole against the info_hash it already has.
  """
  @spec encode_ut_metadata_data(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def encode_ut_metadata_data(ext_id, piece_index, raw_info_bytes) do
    total_size = byte_size(raw_info_bytes)
    offset = piece_index * @block_size
    chunk_len = min(@block_size, total_size - offset)
    chunk = binary_part(raw_info_bytes, offset, chunk_len)

    dict = [{"msg_type", 1}, {"piece", piece_index}, {"total_size", total_size}]
    encode_extended(ext_id, Bencode.encode(dict) <> chunk)
  end

  @doc "Encodes a ut_metadata `reject` message for metadata piece `piece_index`."
  @spec encode_ut_metadata_reject(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_ut_metadata_reject(ext_id, piece_index) do
    dict = [{"msg_type", 2}, {"piece", piece_index}]
    encode_extended(ext_id, Bencode.encode(dict))
  end

  @doc """
  Decodes a ut_metadata message payload (the bytes after the ext_id byte)
  into `{:request, piece}`, `{:data, piece, total_size, raw_chunk}`, or
  `{:reject, piece}`.
  """
  @spec decode_ut_metadata(binary()) :: {:ok, term()} | {:error, term()}
  def decode_ut_metadata(payload) do
    with {:ok, dict, rest} <- Bencode.decode(payload) do
      piece = dict_get(dict, "piece")

      case dict_get(dict, "msg_type") do
        0 -> {:ok, {:request, piece}}
        1 -> {:ok, {:data, piece, dict_get(dict, "total_size"), rest}}
        2 -> {:ok, {:reject, piece}}
        other -> {:error, {:unknown_ut_metadata_msg_type, other}}
      end
    end
  end

  defp dict_get(pairs, key) do
    Enum.find_value(pairs, fn {k, v} -> if k == key, do: v end)
  end

  @doc "The BEP 9 metadata block size (16 KiB)."
  def block_size, do: @block_size
end
