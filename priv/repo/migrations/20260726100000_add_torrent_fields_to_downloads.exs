defmodule Flux.Repo.Migrations.AddTorrentFieldsToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      add :magnet_uri, :string
      add :info_dict, :binary
      add :piece_length, :integer
      add :bitfield, :binary, null: false, default: <<>>
      add :save_path, :string, null: false, default: ""
      add :uploaded, :integer, null: false, default: 0
      add :error_message, :string
    end

    # SQLite has no ALTER TABLE ADD CONSTRAINT; :state/:uploaded validity
    # (including the new :checking value) is enforced entirely in
    # Flux.Downloads.Download's changeset, per the existing pattern.
  end
end
