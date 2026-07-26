defmodule Flux.Downloads do
  @moduledoc """
  Context for managing torrent downloads.

  Every mutation broadcasts on the `"downloads"` PubSub topic so any
  subscriber (the UI phase's LiveView) finds out about changes without this
  context needing to know who's listening. Broadcast payloads are
  deliberately minimal (just the id and an event tag) — subscribers should
  refetch via `get_download!/1`/`list_downloads/0` rather than trust a
  possibly-stale struct riding along on the message.
  """

  import Ecto.Query, warn: false
  alias Flux.Repo
  alias Flux.Downloads.Download

  @topic "downloads"

  def subscribe do
    Phoenix.PubSub.subscribe(Flux.PubSub, @topic)
  end

  def list_downloads do
    Repo.all(from d in Download, order_by: [desc: d.created_at])
  end

  def get_download!(id), do: Repo.get!(Download, id)

  def get_download_by_info_hash(info_hash) do
    Repo.get_by(Download, info_hash: info_hash)
  end

  def create_download(attrs) do
    %Download{}
    |> Download.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:download_added)
  end

  def update_download(%Download{} = download, attrs) do
    download
    |> Download.changeset(attrs)
    |> Repo.update()
    |> broadcast(:download_updated)
  end

  @doc """
  Persists download progress and, optionally, the current piece bitfield
  (the wire-format bytes from `Flux.Torrent.Bitfield.to_wire/1`) so a resume
  doesn't need to re-download already-verified pieces.
  """
  def update_progress(%Download{} = download, downloaded, bitfield \\ nil)
      when is_integer(downloaded) do
    state = if downloaded >= download.total_length, do: :completed, else: download.state

    attrs =
      %{downloaded: downloaded, state: state}
      |> maybe_put(:bitfield, bitfield)

    update_download(download, attrs)
  end

  def update_uploaded(%Download{} = download, uploaded) when is_integer(uploaded) do
    update_download(download, %{uploaded: uploaded})
  end

  def mark_failed(%Download{} = download, reason) when is_binary(reason) do
    update_download(download, %{state: :failed, error_message: reason})
  end

  def mark_checking(%Download{} = download) do
    update_download(download, %{state: :checking, error_message: nil})
  end

  def mark_downloading(%Download{} = download) do
    update_download(download, %{state: :downloading, error_message: nil})
  end

  def delete_download(%Download{} = download) do
    download
    |> Repo.delete()
    |> broadcast(:download_removed)
  end

  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp broadcast({:ok, download} = result, event) do
    Phoenix.PubSub.broadcast(Flux.PubSub, @topic, {event, download.id})
    result
  end

  defp broadcast(result, _event), do: result
end
