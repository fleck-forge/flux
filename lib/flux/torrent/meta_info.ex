defmodule Flux.Torrent.MetaInfo do
  @moduledoc """
  Parses a raw `.torrent` bencoded blob (or a BEP 9-assembled magnet metadata
  blob) into a normalized struct describing a torrent's identity and layout.

  Single-file and multi-file torrents are normalized into the same `files`
  shape (a single-file torrent becomes a one-entry list using the top-level
  `name` as its sole path segment), so `Flux.Torrent.Storage` never needs to
  special-case layout.

  The `info_hash` is computed from the exact raw bytes of the top-level
  `info` dict as they appeared in the original binary — walking the
  top-level dict by hand (rather than trusting `Flux.Bencode.decode/1`'s
  already-decoded value and re-encoding it) is what makes this correct: a
  decode-then-re-encode round trip is not guaranteed to reproduce the
  original bytes if a reference encoder used different key ordering or
  encoding conventions than ours, and the info_hash is a hard correctness
  requirement (peers, trackers, and magnet links all key off it).
  """

  alias Flux.Bencode

  @type file_entry :: %{path: [String.t()], length: non_neg_integer()}

  @type t :: %__MODULE__{
          info_hash: binary(),
          raw_info_bytes: binary(),
          name: String.t(),
          piece_length: pos_integer(),
          pieces: [binary()],
          files: [file_entry()],
          total_length: non_neg_integer(),
          trackers: [[String.t()]],
          private?: boolean()
        }

  defstruct [
    :info_hash,
    :raw_info_bytes,
    :name,
    :piece_length,
    :pieces,
    :files,
    :total_length,
    :trackers,
    private?: false
  ]

  @doc "Parses a raw `.torrent` file's bencoded bytes."
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(raw_torrent_binary) when is_binary(raw_torrent_binary) do
    with {:ok, top_pairs, _rest} <- walk_top_dict(raw_torrent_binary),
         {:ok, info_value, raw_info_bytes} <- fetch_info_span(top_pairs) do
      from_info(info_value, raw_info_bytes, trackers_from(top_pairs))
    end
  end

  @doc """
  Parses an already-assembled info dict's raw bytes (the result of a BEP 9
  ut_metadata exchange for a magnet link) directly — no wrapping top-level
  dict is present in this case, since BEP 9 metadata pieces reassemble
  directly into the info dict's own bytes.
  """
  @spec parse_info_dict(binary(), [[String.t()]]) :: {:ok, t()} | {:error, term()}
  def parse_info_dict(raw_info_bytes, trackers \\ []) when is_binary(raw_info_bytes) do
    with {:ok, info_value} <- Bencode.decode_full(raw_info_bytes) do
      from_info(info_value, raw_info_bytes, trackers)
    end
  end

  defp from_info(info_value, raw_info_bytes, trackers) when is_list(info_value) do
    with {:ok, name} <- fetch(info_value, "name"),
         {:ok, piece_length} <- fetch(info_value, "piece length"),
         {:ok, pieces_bin} <- fetch(info_value, "pieces"),
         {:ok, pieces} <- chunk_pieces(pieces_bin),
         {:ok, files} <- files_from(info_value, name) do
      {:ok,
       %__MODULE__{
         info_hash: :crypto.hash(:sha, raw_info_bytes),
         raw_info_bytes: raw_info_bytes,
         name: name,
         piece_length: piece_length,
         pieces: pieces,
         files: files,
         total_length: Enum.sum(Enum.map(files, & &1.length)),
         trackers: trackers,
         private?: get(info_value, "private") == 1
       }}
    end
  end

  defp from_info(_info_value, _raw_info_bytes, _trackers), do: {:error, :info_not_a_dict}

  defp files_from(info_value, name) do
    case get(info_value, "files") do
      nil ->
        with {:ok, length} <- fetch(info_value, "length") do
          {:ok, [%{path: [name], length: length}]}
        end

      files when is_list(files) ->
        map_ok(files, fn entry ->
          with {:ok, length} <- fetch(entry, "length"),
               {:ok, path} <- fetch(entry, "path") do
            {:ok, %{path: [name | path], length: length}}
          end
        end)

      _ ->
        {:error, :invalid_files}
    end
  end

  defp chunk_pieces(bin) when rem(byte_size(bin), 20) == 0 do
    {:ok, for(<<chunk::binary-size(20) <- bin>>, do: chunk)}
  end

  defp chunk_pieces(_bin), do: {:error, :invalid_pieces_length}

  defp trackers_from(top_pairs) do
    case get(top_pairs, "announce-list") do
      list when is_list(list) and list != [] ->
        Enum.map(list, fn tier -> Enum.filter(tier, &is_binary/1) end)

      _ ->
        case get(top_pairs, "announce") do
          announce when is_binary(announce) -> [[announce]]
          _ -> []
        end
    end
  end

  # Walks a top-level bencoded dict by hand (rather than delegating fully to
  # `Flux.Bencode.decode/1`) so that, for the "info" key specifically, we can
  # capture the exact raw byte span of its value alongside the decoded value
  # itself — see moduledoc for why this matters.
  defp walk_top_dict(<<"d", rest::binary>>), do: walk_entries(rest, [])
  defp walk_top_dict(_), do: {:error, :not_a_dict}

  defp walk_entries(<<"e", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp walk_entries(bin, acc) do
    with {:ok, key, after_key} <- Bencode.decode(bin),
         {:ok, value, after_value} <- Bencode.decode(after_key) do
      raw_value_bytes = binary_part(after_key, 0, byte_size(after_key) - byte_size(after_value))
      walk_entries(after_value, [{key, value, raw_value_bytes} | acc])
    end
  end

  defp fetch_info_span(top_pairs) do
    case Enum.find(top_pairs, fn {k, _v, _raw} -> k == "info" end) do
      {"info", value, raw} -> {:ok, value, raw}
      nil -> {:error, :missing_info}
    end
  end

  defp fetch(pairs, key) do
    case get(pairs, key) do
      nil -> {:error, {:missing_key, key}}
      value -> {:ok, value}
    end
  end

  defp get(pairs, key) do
    Enum.find_value(pairs, fn
      {^key, value} -> {:ok, value}
      {^key, value, _raw} -> {:ok, value}
      _ -> nil
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
