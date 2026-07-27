defmodule Flux.Torrent.Utp.PacketTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Utp.Packet

  defp base_packet(type, payload \\ <<>>) do
    %{
      type: type,
      connection_id: 12_345,
      timestamp_us: 1_000_000,
      timestamp_diff_us: 500,
      wnd_size: 1_048_576,
      seq_nr: 1,
      ack_nr: 0,
      payload: payload
    }
  end

  test "encode/decode round-trips an ST_SYN packet with no payload" do
    packet = base_packet(:st_syn)
    assert {:ok, decoded} = Packet.decode(Packet.encode(packet))
    assert decoded == packet
  end

  test "encode/decode round-trips an ST_DATA packet with a payload" do
    packet = base_packet(:st_data, "hello utp")
    assert {:ok, decoded} = Packet.decode(Packet.encode(packet))
    assert decoded == packet
  end

  test "encode/decode round-trips ST_FIN, ST_STATE, ST_RESET" do
    for type <- [:st_fin, :st_state, :st_reset] do
      packet = base_packet(type)
      assert {:ok, %{type: ^type}} = Packet.decode(Packet.encode(packet))
    end
  end

  test "the encoded header is exactly 20 bytes before the payload" do
    encoded = Packet.encode(base_packet(:st_data, "xyz"))
    assert byte_size(encoded) == 23
  end

  test "decode skips an unrecognized extension chain and still finds the payload" do
    # Hand-build a packet with one extension (next=0, i.e. last in chain)
    # carrying 4 bytes of opaque data (e.g. a selective-ACK bitmask we don't
    # implement), followed by the real payload.
    header =
      <<0::4, 1::4, 1::8, 12_345::16, 1_000_000::32, 500::32, 1_048_576::32, 1::16, 0::16>>

    extension = <<0::8, 4::8, 0xFF, 0xFF, 0xFF, 0xFF>>
    payload = "real data"

    assert {:ok, %{payload: ^payload, type: :st_data}} =
             Packet.decode(header <> extension <> payload)
  end

  test "decode returns an error for a truncated header" do
    assert {:error, _reason} = Packet.decode(<<1, 2, 3>>)
  end

  test "decode returns an error for an unknown packet type id" do
    header =
      <<15::4, 1::4, 0::8, 0::16, 0::32, 0::32, 0::32, 0::16, 0::16>>

    assert {:error, :unknown_packet_type} = Packet.decode(header)
  end

  test "decode returns an error for a truncated extension chain" do
    header =
      <<0::4, 1::4, 1::8, 0::16, 0::32, 0::32, 0::32, 0::16, 0::16>>

    # Claims a 10-byte extension but only provides 2.
    truncated_extension = <<0::8, 10::8, 1, 2>>

    assert {:error, :truncated_extension} = Packet.decode(header <> truncated_extension)
  end
end
