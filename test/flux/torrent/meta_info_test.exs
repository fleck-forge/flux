defmodule Flux.Torrent.MetaInfoTest do
  use ExUnit.Case, async: true

  alias Flux.Bencode
  alias Flux.Torrent.MetaInfo

  defp piece(n), do: :crypto.hash(:sha, "piece#{n}")

  describe "parse/1 — single-file torrent" do
    setup do
      pieces_bin = piece(0) <> piece(1)

      info_pairs = [
        {"length", 100},
        {"name", "movie.mkv"},
        {"piece length", 50},
        {"pieces", pieces_bin}
      ]

      raw_info_bytes = Bencode.encode(info_pairs)

      top_pairs = [
        {"announce", "http://tracker.example/announce"},
        {"info", info_pairs}
      ]

      raw_torrent = Bencode.encode(top_pairs)

      %{raw_torrent: raw_torrent, raw_info_bytes: raw_info_bytes, pieces_bin: pieces_bin}
    end

    test "parses fields correctly", %{raw_torrent: raw_torrent} do
      assert {:ok, meta} = MetaInfo.parse(raw_torrent)
      assert meta.name == "movie.mkv"
      assert meta.piece_length == 50
      assert meta.total_length == 100
      assert meta.files == [%{path: ["movie.mkv"], length: 100}]
      assert length(meta.pieces) == 2
      assert meta.trackers == [["http://tracker.example/announce"]]
      refute meta.private?
    end

    test "computes info_hash from the exact raw info-dict bytes", %{
      raw_torrent: raw_torrent,
      raw_info_bytes: raw_info_bytes
    } do
      assert {:ok, meta} = MetaInfo.parse(raw_torrent)
      assert meta.info_hash == :crypto.hash(:sha, raw_info_bytes)
      assert meta.raw_info_bytes == raw_info_bytes
    end

    test "splits the pieces binary into 20-byte hashes", %{
      raw_torrent: raw_torrent,
      pieces_bin: pieces_bin
    } do
      assert {:ok, meta} = MetaInfo.parse(raw_torrent)
      assert meta.pieces == [binary_part(pieces_bin, 0, 20), binary_part(pieces_bin, 20, 20)]
    end
  end

  describe "parse/1 — multi-file torrent" do
    setup do
      pieces_bin = piece(0)

      info_pairs = [
        {"files",
         [
           [{"length", 10}, {"path", ["a.txt"]}],
           [{"length", 20}, {"path", ["sub", "b.txt"]}]
         ]},
        {"name", "my-torrent"},
        {"piece length", 50},
        {"pieces", pieces_bin}
      ]

      top_pairs = [
        {"announce-list", [["http://tracker1.example/a"], ["http://tracker2.example/a"]]},
        {"info", info_pairs}
      ]

      %{raw_torrent: Bencode.encode(top_pairs)}
    end

    test "normalizes multi-file layout, prefixing paths with the torrent name", %{
      raw_torrent: raw_torrent
    } do
      assert {:ok, meta} = MetaInfo.parse(raw_torrent)

      assert meta.files == [
               %{path: ["my-torrent", "a.txt"], length: 10},
               %{path: ["my-torrent", "sub", "b.txt"], length: 20}
             ]

      assert meta.total_length == 30
    end

    test "prefers announce-list over announce, preserving tiers", %{raw_torrent: raw_torrent} do
      assert {:ok, meta} = MetaInfo.parse(raw_torrent)

      assert meta.trackers == [
               ["http://tracker1.example/a"],
               ["http://tracker2.example/a"]
             ]
    end
  end

  describe "parse/1 — malformed input" do
    test "errors when info dict is missing" do
      raw = Bencode.encode([{"announce", "http://x"}])
      assert {:error, :missing_info} = MetaInfo.parse(raw)
    end

    test "errors when pieces length isn't a multiple of 20" do
      info_pairs = [
        {"length", 10},
        {"name", "x"},
        {"piece length", 50},
        {"pieces", "not-twenty-bytes"}
      ]

      raw = Bencode.encode([{"info", info_pairs}])
      assert {:error, :invalid_pieces_length} = MetaInfo.parse(raw)
    end

    test "errors on required key missing from info dict" do
      info_pairs = [{"name", "x"}, {"piece length", 50}, {"pieces", piece(0)}]
      raw = Bencode.encode([{"info", info_pairs}])
      assert {:error, {:missing_key, "length"}} = MetaInfo.parse(raw)
    end
  end

  describe "parse_info_dict/2 — magnet/BEP9 assembled metadata" do
    test "parses a raw info dict directly (no wrapping torrent dict)" do
      info_pairs = [
        {"length", 5},
        {"name", "magnet-file"},
        {"piece length", 50},
        {"pieces", piece(0)}
      ]

      raw_info_bytes = Bencode.encode(info_pairs)

      assert {:ok, meta} =
               MetaInfo.parse_info_dict(raw_info_bytes, [["http://tracker.example/a"]])

      assert meta.name == "magnet-file"
      assert meta.info_hash == :crypto.hash(:sha, raw_info_bytes)
      assert meta.trackers == [["http://tracker.example/a"]]
    end
  end
end
