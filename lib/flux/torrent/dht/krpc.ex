defmodule Flux.Torrent.Dht.Krpc do
  @moduledoc """
  Pure encode/decode for BEP 5's KRPC protocol — bencoded dicts over UDP,
  which is why this needs no new low-level parsing: it's just specific
  `Flux.Bencode`-shaped dicts (`{t, y, q, a}` for a query, `{t, y, r}` for a
  response, `{t, y, e}` for an error), reusing the same `{value, rest}`
  bencode codec the rest of the engine already relies on.
  """

  alias Flux.Bencode

  @type node_info :: {node_id :: binary(), :inet.ip4_address(), :inet.port_number()}

  @doc "Encodes a query message (`y: \"q\"`) for `query_name` (e.g. \"ping\") with bencode-shaped `args_pairs`."
  @spec encode_query(binary(), String.t(), Bencode.t()) :: binary()
  def encode_query(transaction_id, query_name, args_pairs) do
    Bencode.encode([{"a", args_pairs}, {"q", query_name}, {"t", transaction_id}, {"y", "q"}])
  end

  @doc "Encodes a response message (`y: \"r\"`) with bencode-shaped `response_pairs`."
  @spec encode_response(binary(), Bencode.t()) :: binary()
  def encode_response(transaction_id, response_pairs) do
    Bencode.encode([{"r", response_pairs}, {"t", transaction_id}, {"y", "r"}])
  end

  @doc "Encodes an error message (`y: \"e\"`)."
  @spec encode_error(binary(), integer(), String.t()) :: binary()
  def encode_error(transaction_id, code, message) do
    Bencode.encode([{"e", [code, message]}, {"t", transaction_id}, {"y", "e"}])
  end

  @doc """
  Decodes a raw KRPC packet into `{:ok, message}` where `message` is one of:

    * `%{type: :query, transaction_id:, query:, args: %{id:, target:, info_hash:, port:, token:, implied_port:}}`
    * `%{type: :response, transaction_id:, id:, nodes:, values:, token:}`
    * `%{type: :error, transaction_id:, code:, message:}`

  Fields that don't apply to a given query/response are simply `nil`.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(binary) do
    with {:ok, top} <- Bencode.decode_full(binary) do
      case get(top, "y") do
        "q" -> decode_query(top)
        "r" -> decode_response(top)
        "e" -> decode_error(top)
        _ -> {:error, :unknown_message_type}
      end
    end
  end

  defp decode_query(top) do
    with tid when is_binary(tid) <- get(top, "t") || {:error, :missing_transaction_id},
         query when is_binary(query) <- get(top, "q") || {:error, :missing_query_name},
         args when is_list(args) <- get(top, "a") || {:error, :missing_args} do
      {:ok, %{type: :query, transaction_id: tid, query: query, args: args_to_map(args)}}
    end
  end

  defp decode_response(top) do
    with tid when is_binary(tid) <- get(top, "t") || {:error, :missing_transaction_id},
         r when is_list(r) <- get(top, "r") || {:error, :missing_response} do
      {:ok,
       %{
         type: :response,
         transaction_id: tid,
         id: get(r, "id"),
         nodes: decode_compact_nodes(get(r, "nodes")),
         values: decode_compact_peers(get(r, "values")),
         token: get(r, "token")
       }}
    end
  end

  defp decode_error(top) do
    with tid when is_binary(tid) <- get(top, "t") || {:error, :missing_transaction_id},
         [code, message] <- get(top, "e") || {:error, :missing_error} do
      {:ok, %{type: :error, transaction_id: tid, code: code, message: message}}
    else
      _ -> {:error, :malformed_error}
    end
  end

  defp args_to_map(pairs) do
    %{
      id: get(pairs, "id"),
      target: get(pairs, "target"),
      info_hash: get(pairs, "info_hash"),
      port: get(pairs, "port"),
      token: get(pairs, "token"),
      implied_port: get(pairs, "implied_port")
    }
  end

  @doc "Encodes a list of `{node_id, ip, port}` into BEP 5 compact node info (26 bytes each, concatenated)."
  @spec encode_compact_nodes([node_info()]) :: binary()
  def encode_compact_nodes(nodes) do
    Enum.map_join(nodes, fn {node_id, {a, b, c, d}, port} ->
      <<node_id::binary-size(20), a, b, c, d, port::16>>
    end)
  end

  @doc "Decodes BEP 5 compact node info bytes into a list of `{node_id, ip, port}`."
  @spec decode_compact_nodes(binary() | nil) :: [node_info()]
  def decode_compact_nodes(nil), do: []

  def decode_compact_nodes(bin) when is_binary(bin) and rem(byte_size(bin), 26) == 0 do
    for <<node_id::binary-size(20), a, b, c, d, port::16 <- bin>>,
      do: {node_id, {a, b, c, d}, port}
  end

  def decode_compact_nodes(_), do: []

  @doc "Decodes a `values` list (each entry a 6-byte compact peer string) into `{ip, port}` tuples."
  @spec decode_compact_peers([binary()] | nil) :: [{:inet.ip4_address(), :inet.port_number()}]
  def decode_compact_peers(nil), do: []

  def decode_compact_peers(list) when is_list(list) do
    for bin <- list, is_binary(bin), byte_size(bin) == 6 do
      <<a, b, c, d, port::16>> = bin
      {{a, b, c, d}, port}
    end
  end

  def decode_compact_peers(_), do: []

  defp get(pairs, key) do
    Enum.find_value(pairs, fn {k, v} -> if k == key, do: v end)
  end
end
