defmodule Flux.Torrent.StorageTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.{Storage, MetaInfo}

  @moduletag :tmp_dir

  defp meta_info(files, piece_length, pieces) do
    %MetaInfo{
      info_hash: :crypto.hash(:sha, "x"),
      raw_info_bytes: "x",
      name: "test",
      piece_length: piece_length,
      pieces: pieces,
      files: files,
      total_length: Enum.sum(Enum.map(files, & &1.length)),
      trackers: [],
      private?: false
    }
  end

  describe "single-file torrent" do
    setup %{tmp_dir: tmp_dir} do
      data = "0123456789ABCDEF" |> :binary.copy(2)
      piece_length = 16
      pieces = for <<chunk::binary-size(16) <- data>>, do: :crypto.hash(:sha, chunk)

      meta = meta_info([%{path: ["file.bin"], length: byte_size(data)}], piece_length, pieces)
      {:ok, pid} = Storage.start_link(meta_info: meta, save_path: tmp_dir)

      %{pid: pid, data: data, tmp_dir: tmp_dir}
    end

    test "writes and reads back a block", %{pid: pid, data: data} do
      :ok = Storage.write_block(pid, 0, 0, binary_part(data, 0, 16))
      :ok = Storage.write_block(pid, 1, 0, binary_part(data, 16, 16))

      {:ok, first} = Storage.read_block(pid, 0, 0, 16)
      {:ok, second} = Storage.read_block(pid, 1, 0, 16)
      assert first <> second == data
    end

    test "verify_piece/2 succeeds for correctly written data", %{pid: pid, data: data} do
      :ok = Storage.write_block(pid, 0, 0, binary_part(data, 0, 16))
      :ok = Storage.write_block(pid, 1, 0, binary_part(data, 16, 16))

      assert :ok = Storage.verify_piece(pid, 0)
      assert :ok = Storage.verify_piece(pid, 1)
    end

    test "verify_piece/2 fails for corrupted data", %{pid: pid} do
      :ok = Storage.write_block(pid, 0, 0, :binary.copy(<<0>>, 16))
      assert {:error, :hash_mismatch} = Storage.verify_piece(pid, 0)
    end

    test "verify_existing/1 reports only correctly-written pieces", %{pid: pid, data: data} do
      :ok = Storage.write_block(pid, 0, 0, binary_part(data, 0, 16))
      # piece 1 left unwritten (all zero bytes on disk) -> hash mismatch

      assert {:ok, bitfield} = Storage.verify_existing(pid)
      assert Flux.Torrent.Bitfield.has?(bitfield, 0)
      refute Flux.Torrent.Bitfield.has?(bitfield, 1)
    end

  end

  describe "multi-file torrent with a block straddling a file boundary" do
    setup %{tmp_dir: tmp_dir} do
      # file "a" is 10 bytes, file "b" is 10 bytes, piece_length 16 -> the
      # single piece (16 bytes) straddles both files (bytes 0-9 in a, 10-15
      # in b).
      data = for i <- 0..15, into: <<>>, do: <<i>>
      pieces = [:crypto.hash(:sha, data)]

      meta =
        meta_info(
          [%{path: ["a.bin"], length: 10}, %{path: ["b.bin"], length: 6}],
          16,
          pieces
        )

      {:ok, pid} = Storage.start_link(meta_info: meta, save_path: tmp_dir)
      %{pid: pid, data: data, tmp_dir: tmp_dir}
    end

    test "a single write_block call splits across both files and reads back correctly", %{
      pid: pid,
      data: data,
      tmp_dir: tmp_dir
    } do
      :ok = Storage.write_block(pid, 0, 0, data)

      assert {:ok, read_back} = Storage.read_block(pid, 0, 0, 16)
      assert read_back == data

      assert {:ok, a_bin} = File.read(Path.join(tmp_dir, "a.bin"))
      assert {:ok, b_bin} = File.read(Path.join(tmp_dir, "b.bin"))
      assert a_bin == binary_part(data, 0, 10)
      assert b_bin == binary_part(data, 10, 6)
    end

    test "verify_piece succeeds against the straddling piece hash", %{pid: pid, data: data} do
      :ok = Storage.write_block(pid, 0, 0, data)
      assert :ok = Storage.verify_piece(pid, 0)
    end
  end
end
