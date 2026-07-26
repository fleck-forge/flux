defmodule Flux.Bencode do
  @moduledoc """
  Minimal bencode (BEP 3) encoder/decoder.

  `decode/1` returns the unconsumed remainder of the input alongside the
  decoded value. Since BEAM binaries share their underlying buffer on
  pattern-match slicing, `byte_size(input) - byte_size(rest)` tells a caller
  exactly how many raw bytes were consumed — callers that need the exact raw
  byte span of a value (e.g. `Flux.Torrent.MetaInfo` capturing the `info`
  dict's original bytes for SHA-1 hashing) can derive it from this without
  the decoder needing a separate span-tracking API.

  Dict keys decode as binaries (bencoded byte strings), not atoms, and are
  returned in on-the-wire order as a list of `{key, value}` pairs rather than
  a map — this keeps this module a pure/generic bencode codec, without
  baking in assumptions about specific keys (like "info") that only
  higher-level torrent-parsing code cares about.
  """

  @type t :: integer() | binary() | list(t()) | [{binary(), t()}]

  @doc "Encodes a term into its bencoded binary representation."
  @spec encode(t()) :: binary()
  def encode(int) when is_integer(int), do: "i#{int}e"

  def encode(bin) when is_binary(bin), do: "#{byte_size(bin)}:#{bin}"

  def encode(list) when is_list(list) do
    case list do
      [{k, _} | _] when is_binary(k) -> encode_dict(list)
      _ -> encode_list(list)
    end
  end

  def encode([]), do: "le"

  defp encode_list(list) do
    body = Enum.map_join(list, &encode/1)
    "l#{body}e"
  end

  defp encode_dict(pairs) do
    body =
      pairs
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(fn {k, v} -> encode(k) <> encode(v) end)

    "d#{body}e"
  end

  @doc """
  Decodes exactly one bencoded value from the head of `binary`.

  Returns `{:ok, value, rest}` where `rest` is whatever followed the decoded
  value, or `{:error, reason}` on malformed input.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    do_decode(binary)
  rescue
    _ -> {:error, :invalid_bencode}
  end

  @doc "Like `decode/1`, but requires the entire binary to be consumed."
  @spec decode_full(binary()) :: {:ok, t()} | {:error, term()}
  def decode_full(binary) do
    case decode(binary) do
      {:ok, value, ""} -> {:ok, value}
      {:ok, _value, _rest} -> {:error, :trailing_data}
      {:error, _} = error -> error
    end
  end

  defp do_decode(<<"i", rest::binary>>), do: decode_integer(rest)
  defp do_decode(<<"l", rest::binary>>), do: decode_list(rest, [])
  defp do_decode(<<"d", rest::binary>>), do: decode_dict(rest, [])

  defp do_decode(<<c, _::binary>> = binary) when c in ?0..?9 do
    decode_string(binary)
  end

  defp do_decode(_), do: {:error, :invalid_bencode}

  defp decode_integer(binary) do
    case String.split(binary, "e", parts: 2) do
      [digits, rest] ->
        case parse_int(digits) do
          {:ok, int} -> {:ok, int, rest}
          :error -> {:error, :invalid_integer}
        end

      _ ->
        {:error, :unterminated_integer}
    end
  end

  # Rejects leading zeros ("03"), a bare "-0", and non-digit content — bencode
  # integers must be a minimal decimal representation.
  defp parse_int("0"), do: {:ok, 0}
  defp parse_int("-0"), do: :error

  defp parse_int(<<"-", digits::binary>>) do
    with true <- digits != "", true <- valid_digits?(digits), {:ok, n} <- to_int(digits) do
      {:ok, -n}
    else
      _ -> :error
    end
  end

  defp parse_int(digits) do
    with true <- digits != "", true <- valid_digits?(digits), {:ok, n} <- to_int(digits) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp valid_digits?(<<"0", _::binary>>), do: false
  defp valid_digits?(digits), do: String.match?(digits, ~r/^\d+$/)

  defp to_int(digits) do
    case Integer.parse(digits) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp decode_string(binary) do
    case String.split(binary, ":", parts: 2) do
      [len_str, rest] ->
        case parse_length(len_str) do
          {:ok, len} when byte_size(rest) >= len ->
            <<value::binary-size(len), remainder::binary>> = rest
            {:ok, value, remainder}

          {:ok, _len} ->
            {:error, :string_too_short}

          :error ->
            {:error, :invalid_string_length}
        end

      _ ->
        {:error, :invalid_string}
    end
  end

  defp parse_length(len_str) do
    if len_str != "" and String.match?(len_str, ~r/^\d+$/) do
      {:ok, String.to_integer(len_str)}
    else
      :error
    end
  end

  defp decode_list(<<"e", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_list(binary, acc) do
    case do_decode(binary) do
      {:ok, value, rest} -> decode_list(rest, [value | acc])
      {:error, _} = error -> error
    end
  end

  defp decode_dict(<<"e", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_dict(binary, acc) do
    with {:ok, key, after_key} <- decode_string(binary),
         {:ok, value, after_value} <- do_decode(after_key) do
      decode_dict(after_value, [{key, value} | acc])
    else
      {:error, _} = error -> error
    end
  end
end
