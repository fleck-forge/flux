defmodule Flux.Torrent do
  @moduledoc """
  Public facade for the BitTorrent engine. This is the *only* module the
  UI phase (or anything else outside `lib/flux/torrent/`) should call into
  — everything else (`Session`, `Session.Worker`, `PeerConnection`,
  `Storage`, ...) is an internal implementation detail reached only
  through here.
  """

  alias Flux.Downloads
  alias Flux.Torrent.{MetaInfo, Magnet}

  @doc "Adds a torrent from a raw `.torrent` file's bytes and starts downloading it."
  @spec add_torrent_file(binary(), String.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def add_torrent_file(raw_torrent_binary, save_path) do
    with {:ok, meta_info} <- MetaInfo.parse(raw_torrent_binary) do
      attrs = %{
        name: meta_info.name,
        info_hash: meta_info.info_hash,
        total_length: meta_info.total_length,
        save_path: save_path,
        info_dict: meta_info.raw_info_bytes,
        piece_length: meta_info.piece_length,
        trackers: Jason.encode!(meta_info.trackers)
      }

      create_and_start(attrs)
    end
  end

  @doc """
  Adds a torrent from a magnet URI and starts downloading it. Metadata
  (name, size, piece layout) isn't known yet — it's resolved asynchronously
  via BEP 9/10 peer exchange, after which the download's row is updated in
  place. A magnet with no tracker parameters fails fast (no DHT fallback).
  """
  @spec add_magnet(String.t(), String.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def add_magnet(magnet_uri, save_path) do
    with {:ok, magnet} <- Magnet.parse(magnet_uri) do
      attrs = %{
        name: magnet.name || "Magnet (resolving...)",
        info_hash: magnet.info_hash,
        total_length: 0,
        save_path: save_path,
        magnet_uri: magnet_uri,
        trackers: Jason.encode!(Enum.map(magnet.trackers, &[&1]))
      }

      create_and_start(attrs)
    end
  end

  defp create_and_start(attrs) do
    with {:ok, download} <- Downloads.create_download(attrs),
         :ok <- start_session(download.id) do
      {:ok, download.id}
    end
  end

  @doc "Pauses a download: stops its session (peer connections included) and persists progress made so far."
  @spec pause(binary()) :: :ok | {:error, term()}
  def pause(info_hash) do
    with %Downloads.Download{} = download <-
           Downloads.get_download_by_info_hash(info_hash) || :not_found do
      stop_session(download.id)
      {:ok, _} = Downloads.mark_paused(download)
      :ok
    else
      :not_found -> {:error, :not_found}
    end
  end

  @doc "Resumes a paused (or previously-failed) download."
  @spec resume(binary()) :: :ok | {:error, term()}
  def resume(info_hash) do
    with %Downloads.Download{} = download <-
           Downloads.get_download_by_info_hash(info_hash) || :not_found do
      start_session(download.id)
    else
      :not_found -> {:error, :not_found}
    end
  end

  @doc "Removes a download, stopping its session and optionally deleting its on-disk files."
  @spec remove(binary(), boolean()) :: :ok | {:error, term()}
  def remove(info_hash, delete_files? \\ false) do
    with %Downloads.Download{} = download <-
           Downloads.get_download_by_info_hash(info_hash) || :not_found do
      stop_session(download.id)
      if delete_files?, do: delete_files(download)
      {:ok, _} = Downloads.delete_download(download)
      :ok
    else
      :not_found -> {:error, :not_found}
    end
  end

  @empty_stats %{peer_count: 0, connecting_count: 0, tracker_seeders: nil, tracker_leechers: nil}

  @doc """
  Live, in-memory stats for a running session — connected/connecting peer
  count and the last tracker-reported seeder/leecher count (`nil` until the
  first successful announce). Returns zeroed-out stats (not an error) for a
  download with no active session (paused, failed, or not yet resumed after
  boot), since "no live session" and "zero peers" look the same to a caller.
  """
  @spec stats(binary()) :: %{
          peer_count: non_neg_integer(),
          connecting_count: non_neg_integer(),
          tracker_seeders: non_neg_integer() | nil,
          tracker_leechers: non_neg_integer() | nil
        }
  def stats(info_hash) do
    case Registry.lookup(Flux.Torrent.Registry, info_hash) do
      [{pid, _}] -> safe_stats(pid)
      [] -> @empty_stats
    end
  end

  defp safe_stats(pid) do
    GenServer.call(pid, :stats, 2000)
  catch
    :exit, _ -> @empty_stats
  end

  defp delete_files(%{info_dict: nil}), do: :ok

  defp delete_files(download) do
    with {:ok, meta_info} <- MetaInfo.parse_info_dict(download.info_dict) do
      for %{path: path} <- meta_info.files do
        File.rm(Path.join([download.save_path | path]))
      end

      File.rm_rf(download.save_path)
    end

    :ok
  end

  @doc """
  Restarts a session for every download left in `:downloading` or
  `:checking` state — implies the app was killed mid-download last run.
  `:paused` downloads are deliberately NOT auto-resumed (respects an
  explicit user pause). Called once at application boot.
  """
  @spec resume_incomplete_downloads() :: :ok
  def resume_incomplete_downloads do
    Downloads.list_downloads()
    |> Enum.filter(&(&1.state in [:downloading, :checking]))
    |> Enum.each(&start_session(&1.id))

    :ok
  end

  defp start_session(download_id) do
    case DynamicSupervisor.start_child(
           Flux.Torrent.SessionSupervisor,
           {Flux.Torrent.Session, download_id}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_session(download_id) do
    case Registry.lookup(Flux.Torrent.Registry, {:session_sup, download_id}) do
      [{sup_pid, _}] -> DynamicSupervisor.terminate_child(Flux.Torrent.SessionSupervisor, sup_pid)
      [] -> :ok
    end

    :ok
  end
end
