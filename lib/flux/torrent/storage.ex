defmodule Flux.Torrent.Storage do
  @moduledoc """
  Maps piece/block byte offsets onto one or more on-disk files for a single
  torrent (single-file torrents are just a one-entry file list, courtesy of
  `Flux.Torrent.MetaInfo`'s normalization) and performs the actual reads and
  writes.

  A GenServer (not a plain functional module) because multiple
  `Flux.Torrent.PeerConnection` processes write/read concurrently, and
  Erlang file handles aren't safe to share across processes without
  serializing access through one owner.

  Piece-level "have we got all its blocks yet" bookkeeping is deliberately
  NOT this module's job — `Flux.Torrent.Session.Worker` already tracks
  in-flight/received blocks per piece for picker purposes, so duplicating
  that here would just be two sources of truth. This module only knows how
  to durably read/write bytes and verify a piece's hash once asked.
  """

  use GenServer

  defstruct [:meta_info, :save_path, :layout, :handles]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Writes `data` at block `begin` within piece `index`."
  def write_block(pid, index, begin, data) do
    GenServer.call(pid, {:write_block, index, begin, data})
  end

  @doc "Reads `length` bytes at block `begin` within piece `index`."
  def read_block(pid, index, begin, length) do
    GenServer.call(pid, {:read_block, index, begin, length})
  end

  @doc "Reads the whole piece back from disk and checks its SHA-1 hash."
  def verify_piece(pid, index) do
    GenServer.call(pid, {:verify_piece, index})
  end

  @doc """
  Verifies every piece against disk, returning `{:ok, bitfield}` where
  `bitfield` reflects only what's genuinely present and hash-correct right
  now — used when resuming, since a bitfield persisted before an unclean
  shutdown can't be fully trusted.
  """
  def verify_existing(pid) do
    GenServer.call(pid, :verify_existing, :infinity)
  end

  ## Server

  @impl true
  def init(opts) do
    meta_info = Keyword.fetch!(opts, :meta_info)
    save_path = Keyword.fetch!(opts, :save_path)

    layout = build_layout(meta_info.files)

    with :ok <- File.mkdir_p(save_path),
         {:ok, handles} <- open_all(layout, save_path) do
      {:ok,
       %__MODULE__{meta_info: meta_info, save_path: save_path, layout: layout, handles: handles}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    for {_path, handle} <- state.handles, do: :file.close(handle)
    :ok
  end

  @impl true
  def handle_call({:write_block, index, begin, data}, _from, state) do
    offset = index * state.meta_info.piece_length + begin
    reply = write_at(state, offset, data)
    {:reply, reply, state}
  end

  def handle_call({:read_block, index, begin, length}, _from, state) do
    offset = index * state.meta_info.piece_length + begin
    reply = read_at(state, offset, length)
    {:reply, reply, state}
  end

  def handle_call({:verify_piece, index}, _from, state) do
    {:reply, do_verify_piece(state, index), state}
  end

  def handle_call(:verify_existing, _from, state) do
    piece_count = length(state.meta_info.pieces)

    bitfield =
      Enum.reduce(0..(piece_count - 1), Flux.Torrent.Bitfield.new(piece_count), fn index, bf ->
        case do_verify_piece(state, index) do
          :ok -> Flux.Torrent.Bitfield.set(bf, index)
          _ -> bf
        end
      end)

    {:reply, {:ok, bitfield}, state}
  end

  ## Internal

  defp do_verify_piece(state, index) do
    size = piece_size(state.meta_info, index)
    expected_hash = Enum.at(state.meta_info.pieces, index)

    with {:ok, bin} <- read_at(state, index * state.meta_info.piece_length, size) do
      if :crypto.hash(:sha, bin) == expected_hash, do: :ok, else: {:error, :hash_mismatch}
    end
  end

  defp piece_size(meta_info, index) do
    last_index = length(meta_info.pieces) - 1

    if index == last_index do
      meta_info.total_length - index * meta_info.piece_length
    else
      meta_info.piece_length
    end
  end

  defp write_at(state, offset, data) do
    chunks = locate(offset, byte_size(data), state.layout)

    Enum.reduce_while(chunks, {:ok, 0}, fn {file, file_offset, len}, {:ok, written} ->
      part = binary_part(data, written, len)
      handle = Map.fetch!(state.handles, file.path)

      case :file.pwrite(handle, file_offset, part) do
        :ok -> {:cont, {:ok, written + len}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp read_at(state, offset, length) do
    chunks = locate(offset, length, state.layout)

    Enum.reduce_while(chunks, {:ok, <<>>}, fn {file, file_offset, len}, {:ok, acc} ->
      handle = Map.fetch!(state.handles, file.path)

      case :file.pread(handle, file_offset, len) do
        {:ok, data} when byte_size(data) == len ->
          {:cont, {:ok, acc <> data}}

        {:ok, short} ->
          {:cont, {:ok, acc <> short <> :binary.copy(<<0>>, len - byte_size(short))}}

        :eof ->
          {:cont, {:ok, acc <> :binary.copy(<<0>>, len)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Splits a (offset, length) span across whichever file(s) in `layout` it
  # falls within — a block can straddle a file boundary in a multi-file
  # torrent.
  defp locate(_offset, 0, _layout), do: []

  defp locate(offset, length, layout) do
    case Enum.find(layout, fn f -> offset >= f.start and offset < f.start + f.length end) do
      nil ->
        []

      file ->
        file_offset = offset - file.start
        available = file.length - file_offset
        take = min(available, length)
        [{file, file_offset, take} | locate(offset + take, length - take, layout)]
    end
  end

  defp build_layout(files) do
    {layout, _end_offset} =
      Enum.map_reduce(files, 0, fn %{path: path, length: length}, start ->
        {%{path: path, start: start, length: length}, start + length}
      end)

    layout
  end

  defp open_all(layout, save_path) do
    Enum.reduce_while(layout, {:ok, %{}}, fn file, {:ok, acc} ->
      full_path = Path.join([save_path | file.path])

      with :ok <- File.mkdir_p(Path.dirname(full_path)),
           {:ok, handle} <- :file.open(full_path, [:read, :write, :binary]),
           :ok <- ensure_size(handle, full_path, file.length) do
        {:cont, {:ok, Map.put(acc, file.path, handle)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_size(_handle, _path, 0), do: :ok

  defp ensure_size(handle, path, length) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= length -> :ok
      _ -> :file.pwrite(handle, length - 1, <<0>>)
    end
  end

  @doc false
  # Exposed for MetaInfo/tests that want the same normalized layout.
  def layout_for(meta_info), do: build_layout(meta_info.files)
end
