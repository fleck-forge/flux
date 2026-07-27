defmodule Flux.Torrent.Utp.Packet do
  @moduledoc """
  BEP 29 (uTP) packet header encode/decode — pure, no I/O. The full real
  wire format (type/version, an extension chain, connection id, both
  timestamps, window size, sequence/ack numbers) is understood on decode,
  but `Flux.Torrent.Utp.Socket` only ever *sends* packets with no
  extensions — a real peer's extension chain (e.g. selective ACK) is
  walked and skipped rather than interpreted, just enough to still find
  the payload that follows it correctly.
  """

  @version 1

  @type_to_id %{st_data: 0, st_fin: 1, st_state: 2, st_reset: 3, st_syn: 4}
  @id_to_type Map.new(@type_to_id, fn {k, v} -> {v, k} end)

  @type packet_type :: :st_data | :st_fin | :st_state | :st_reset | :st_syn

  @type t :: %{
          type: packet_type(),
          connection_id: char(),
          timestamp_us: non_neg_integer(),
          timestamp_diff_us: non_neg_integer(),
          wnd_size: non_neg_integer(),
          seq_nr: char(),
          ack_nr: char(),
          payload: binary()
        }

  @doc "Encodes a packet map into its 20-byte-header-plus-payload wire form."
  @spec encode(t()) :: binary()
  def encode(packet) do
    type_id = Map.fetch!(@type_to_id, packet.type)

    <<type_id::4, @version::4, 0::8, packet.connection_id::16, packet.timestamp_us::32,
      packet.timestamp_diff_us::32, packet.wnd_size::32, packet.seq_nr::16,
      packet.ack_nr::16>> <> Map.get(packet, :payload, <<>>)
  end

  @doc "Decodes a packet from the wire, skipping (not interpreting) any extension chain."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(
        <<type_id::4, _version::4, extension::8, connection_id::16, timestamp_us::32,
          timestamp_diff_us::32, wnd_size::32, seq_nr::16, ack_nr::16, rest::binary>>
      ) do
    with {:ok, type} <- fetch_type(type_id),
         {:ok, payload} <- skip_extensions(extension, rest) do
      {:ok,
       %{
         type: type,
         connection_id: connection_id,
         timestamp_us: timestamp_us,
         timestamp_diff_us: timestamp_diff_us,
         wnd_size: wnd_size,
         seq_nr: seq_nr,
         ack_nr: ack_nr,
         payload: payload
       }}
    end
  end

  def decode(_other), do: {:error, :invalid_header}

  defp fetch_type(id) do
    case Map.fetch(@id_to_type, id) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_packet_type}
    end
  end

  defp skip_extensions(0, rest), do: {:ok, rest}

  defp skip_extensions(_next, <<next::8, len::8, _ext::binary-size(len), rest::binary>>),
    do: skip_extensions(next, rest)

  defp skip_extensions(_next, _rest), do: {:error, :truncated_extension}
end
