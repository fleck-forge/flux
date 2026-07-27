defmodule Flux.Torrent.Magnet do
  import Bitwise

  @moduledoc """
  Parses `magnet:` URIs (the `xt=urn:btih:`, `dn=`, `tr=` parameters) into the
  minimum needed to start a session before real metadata has been fetched: an
  info_hash, an optional display name, and a tracker list. A magnet with no
  `tr=` parameters parses to an empty `trackers` list and still works —
  `Flux.Torrent.Dht` is the peer-discovery (and, for magnets, metadata
  discovery) path in that case.
  """

  @type t :: %{info_hash: binary(), name: String.t() | nil, trackers: [String.t()]}

  @doc "Parses a magnet URI string."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse("magnet:" <> _ = uri_string) do
    uri = URI.parse(uri_string)

    case uri.query do
      nil ->
        {:error, :missing_query}

      query ->
        params = URI.query_decoder(query) |> Enum.to_list()

        with {:ok, info_hash} <- fetch_info_hash(params) do
          {:ok,
           %{
             info_hash: info_hash,
             name: fetch_first(params, "dn"),
             trackers: fetch_all(params, "tr")
           }}
        end
    end
  end

  def parse(_), do: {:error, :not_a_magnet_uri}

  defp fetch_info_hash(params) do
    case fetch_all(params, "xt") |> Enum.find(&btih?/1) do
      nil -> {:error, :missing_btih}
      xt -> decode_btih(String.trim_leading(xt, "urn:btih:"))
    end
  end

  defp btih?(xt), do: String.starts_with?(xt, "urn:btih:")

  defp decode_btih(hash_str) do
    cond do
      String.length(hash_str) == 40 and hex?(hash_str) ->
        {:ok, Base.decode16!(hash_str, case: :mixed)}

      String.length(hash_str) == 32 ->
        case base32_decode(hash_str) do
          {:ok, bin} when byte_size(bin) == 20 -> {:ok, bin}
          _ -> {:error, :invalid_btih}
        end

      true ->
        {:error, :invalid_btih}
    end
  end

  defp hex?(str), do: String.match?(str, ~r/^[0-9a-fA-F]+$/)

  @base32_alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  # RFC 4648 base32 decode (no padding expected — magnet btih32 values are
  # always exactly 32 chars encoding 20 bytes, so padding never applies).
  defp base32_decode(str) do
    str
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, <<>>, 0, 0}, fn char, {:ok, acc, buffer, bits} ->
      case Enum.find_index(@base32_alphabet, &(&1 == char)) do
        nil ->
          {:halt, {:error, :invalid_base32}}

        value ->
          buffer = buffer <<< 5 ||| value
          bits = bits + 5

          if bits >= 8 do
            bits = bits - 8
            byte = buffer >>> bits &&& 0xFF
            {:cont, {:ok, acc <> <<byte>>, buffer, bits}}
          else
            {:cont, {:ok, acc, buffer, bits}}
          end
      end
    end)
    |> case do
      {:ok, acc, _buffer, _bits} -> {:ok, acc}
      {:error, _} = error -> error
    end
  end

  defp fetch_first(params, key) do
    Enum.find_value(params, fn {k, v} -> if k == key, do: v end)
  end

  defp fetch_all(params, key) do
    for {k, v} <- params, k == key, do: v
  end
end
