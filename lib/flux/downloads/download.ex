defmodule Flux.Downloads.Download do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:downloading, :paused, :completed, :failed, :checking]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "downloads" do
    field :name, :string
    field :info_hash, :binary
    field :total_length, :integer
    field :downloaded, :integer, default: 0
    field :state, Ecto.Enum, values: @states, default: :downloading

    # Torrent-engine fields. `magnet_uri` and `info_dict` are mutually
    # informative rather than mutually exclusive: a magnet-added download
    # starts with only `magnet_uri` set and `info_dict: nil`, and gains
    # `info_dict` (plus a corrected `name`/`total_length`/`piece_length`)
    # once BEP 9 metadata exchange completes. `info_dict` is the raw bytes
    # of the info dict exactly as seen on the wire — see
    # `Flux.Torrent.MetaInfo`'s moduledoc for why re-encoding it is unsafe.
    field :magnet_uri, :string
    field :info_dict, :binary
    field :piece_length, :integer
    field :bitfield, :binary, default: <<>>
    field :save_path, :string
    field :uploaded, :integer, default: 0
    field :error_message, :string

    # JSON-encoded list of tracker tiers (`[["url1"],["url2","url3"]]`),
    # per BEP 12 — these live in a .torrent's top-level dict, not in
    # `info_dict`, so they need their own storage to survive a restart.
    field :trackers, :string, default: "[]"

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  @doc false
  def changeset(download, attrs) do
    download
    |> cast(attrs, [
      :name,
      :info_hash,
      :total_length,
      :downloaded,
      :state,
      :magnet_uri,
      :info_dict,
      :piece_length,
      :bitfield,
      :save_path,
      :uploaded,
      :error_message,
      :trackers
    ])
    |> validate_required([:name, :info_hash, :total_length, :save_path])
    |> validate_number(:total_length, greater_than_or_equal_to: 0)
    |> validate_number(:downloaded, greater_than_or_equal_to: 0)
    |> validate_number(:uploaded, greater_than_or_equal_to: 0)
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:info_hash)
  end

  def states, do: @states
end
