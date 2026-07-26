defmodule Flux.Torrent.WireProtocolTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.WireProtocol, as: WP

  @info_hash :crypto.hash(:sha, "info")
  @peer_id :crypto.hash(:sha, "peer")

  describe "handshake" do
    test "encodes to exactly 68 bytes with the correct pstr" do
      encoded = WP.encode_handshake(@info_hash, @peer_id)
      assert byte_size(encoded) == 68
      assert <<19, "BitTorrent protocol", _::binary>> = encoded
    end

    test "round-trips" do
      encoded = WP.encode_handshake(@info_hash, @peer_id)
      assert {:ok, %{info_hash: ih, peer_id: pid, reserved: reserved}, ""} =
               WP.decode_handshake(encoded)

      assert ih == @info_hash
      assert pid == @peer_id
      assert reserved == <<0, 0, 0, 0, 0, 0, 0, 0>>
    end

    test "leaves trailing bytes (e.g. a following bitfield message) in rest" do
      encoded = WP.encode_handshake(@info_hash, @peer_id) <> "EXTRA"
      assert {:ok, _, "EXTRA"} = WP.decode_handshake(encoded)
    end

    test "reports :incomplete on a truncated handshake" do
      encoded = WP.encode_handshake(@info_hash, @peer_id)
      truncated = binary_part(encoded, 0, 30)
      assert {:incomplete, ^truncated} = WP.decode_handshake(truncated)
    end

    test "rejects a bad protocol string" do
      bad = <<19, "Not BitTorrent proto", 0::size(8*8), @info_hash::binary, @peer_id::binary>>
      assert {:error, :bad_protocol} = WP.decode_handshake(bad)
    end

    test "set_extension_bit/1 and extension_supported?/1" do
      reserved = <<0, 0, 0, 0, 0, 0, 0, 0>>
      refute WP.extension_supported?(reserved)
      extended = WP.set_extension_bit(reserved)
      assert WP.extension_supported?(extended)
    end
  end

  describe "standard messages — round trip + incomplete handling" do
    test "keep_alive" do
      assert WP.encode_message(:keep_alive) == <<0::32>>
      assert WP.decode_message(<<0::32, "rest">>) == {:ok, :keep_alive, "rest"}
    end

    for msg <- [:choke, :unchoke, :interested, :not_interested] do
      test "#{msg}" do
        encoded = WP.encode_message(unquote(msg))
        assert {:ok, unquote(msg), ""} = WP.decode_message(encoded)
      end
    end

    test "have" do
      encoded = WP.encode_message({:have, 7})
      assert {:ok, {:have, 7}, ""} = WP.decode_message(encoded)
    end

    test "bitfield" do
      encoded = WP.encode_message({:bitfield, <<0b10110000>>})
      assert {:ok, {:bitfield, <<0b10110000>>}, ""} = WP.decode_message(encoded)
    end

    test "request" do
      encoded = WP.encode_message({:request, 1, 0, 16_384})
      assert {:ok, {:request, 1, 0, 16_384}, ""} = WP.decode_message(encoded)
    end

    test "piece" do
      encoded = WP.encode_message({:piece, 1, 0, "blockdata"})
      assert {:ok, {:piece, 1, 0, "blockdata"}, ""} = WP.decode_message(encoded)
    end

    test "cancel" do
      encoded = WP.encode_message({:cancel, 1, 0, 16_384})
      assert {:ok, {:cancel, 1, 0, 16_384}, ""} = WP.decode_message(encoded)
    end

    test "port" do
      encoded = WP.encode_message({:port, 6881})
      assert {:ok, {:port, 6881}, ""} = WP.decode_message(encoded)
    end

    test "reports :incomplete when the length prefix exceeds available bytes" do
      encoded = WP.encode_message({:have, 7})
      truncated = binary_part(encoded, 0, 4)
      assert {:incomplete, ^truncated} = WP.decode_message(truncated)
    end

    test "reports :incomplete on fewer than 4 bytes (can't even read the length prefix)" do
      assert {:incomplete, <<1, 2>>} = WP.decode_message(<<1, 2>>)
    end

    test "decodes two consecutive messages from one buffer via chained rest" do
      buffer = WP.encode_message(:choke) <> WP.encode_message({:have, 3})
      assert {:ok, :choke, rest} = WP.decode_message(buffer)
      assert {:ok, {:have, 3}, ""} = WP.decode_message(rest)
    end

    test "errors on an unknown message id" do
      bad = <<2::32, 99, 0>>
      assert {:error, {:unknown_message_id, 99}} = WP.decode_message(bad)
    end
  end

  describe "BEP 10 extended handshake" do
    test "round-trips supported extensions and metadata_size" do
      encoded = WP.encode_extended_handshake(%{"ut_metadata" => 1}, 1234)
      assert {:ok, {:extended, 0, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, %{extensions: %{"ut_metadata" => 1}, metadata_size: 1234}} =
               WP.decode_extended_handshake(payload)
    end

    test "metadata_size is nil when not provided" do
      encoded = WP.encode_extended_handshake(%{"ut_metadata" => 1})
      assert {:ok, {:extended, 0, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, %{metadata_size: nil}} = WP.decode_extended_handshake(payload)
    end
  end

  describe "BEP 9 ut_metadata" do
    @raw_info_bytes :crypto.strong_rand_bytes(20_000)

    test "request message" do
      encoded = WP.encode_ut_metadata_request(1, 0)
      assert {:ok, {:extended, 1, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, {:request, 0}} = WP.decode_ut_metadata(payload)
    end

    test "data message slices the exact original bytes, no re-encoding" do
      encoded = WP.encode_ut_metadata_data(1, 0, @raw_info_bytes)
      assert {:ok, {:extended, 1, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, {:data, 0, total_size, chunk}} = WP.decode_ut_metadata(payload)

      assert total_size == byte_size(@raw_info_bytes)
      assert chunk == binary_part(@raw_info_bytes, 0, 16_384)
    end

    test "data message for the final (short) piece slices only the remaining bytes" do
      last_piece_index = div(byte_size(@raw_info_bytes), 16_384)
      encoded = WP.encode_ut_metadata_data(1, last_piece_index, @raw_info_bytes)
      assert {:ok, {:extended, 1, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, {:data, ^last_piece_index, _total_size, chunk}} = WP.decode_ut_metadata(payload)

      expected_len = byte_size(@raw_info_bytes) - last_piece_index * 16_384
      assert byte_size(chunk) == expected_len
      assert chunk == binary_part(@raw_info_bytes, last_piece_index * 16_384, expected_len)
    end

    test "reject message" do
      encoded = WP.encode_ut_metadata_reject(1, 2)
      assert {:ok, {:extended, 1, payload}, ""} = WP.decode_message(encoded)
      assert {:ok, {:reject, 2}} = WP.decode_ut_metadata(payload)
    end
  end
end
