defmodule Flux.Repo.Migrations.AddVerifiedFromDiskToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      # Set when the download reached :completed via initial disk
      # verification (the file was already fully present and hash-correct
      # at save_path before any peer connection happened) rather than by
      # actually transferring data through this session — surfaced in the
      # UI so a suspiciously-instant completion doesn't look like a fake or
      # broken progress bar.
      add :verified_from_disk, :boolean, null: false, default: false
    end
  end
end
