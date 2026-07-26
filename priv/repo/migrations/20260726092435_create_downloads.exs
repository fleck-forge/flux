defmodule Flux.Repo.Migrations.CreateDownloads do
  use Ecto.Migration

  def change do
    create table(:downloads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :info_hash, :binary, null: false
      add :total_length, :integer, null: false
      add :downloaded, :integer, null: false, default: 0
      add :state, :string, null: false, default: "downloading"

      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:downloads, [:info_hash])
    create index(:downloads, [:state])

    # SQLite has no ALTER TABLE ADD CONSTRAINT, so CHECK constraints can't be
    # added after CREATE TABLE via Ecto.Migration.constraint/3. Validity of
    # :state, :downloaded and :total_length is instead enforced by
    # Flux.Downloads.Download's changeset (Ecto.Enum + validate_number).
  end
end
