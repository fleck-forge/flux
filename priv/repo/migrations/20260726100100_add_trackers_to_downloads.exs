defmodule Flux.Repo.Migrations.AddTrackersToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      # JSON-encoded list-of-tiers (e.g. `[["url1"],["url2","url3"]]`), per
      # BEP 12 announce-list tiers. Needed because trackers live in a
      # .torrent's top-level dict (`announce`/`announce-list`), NOT inside
      # the `info` dict — so they can't be reconstructed from the
      # `info_dict` column alone the way piece layout can.
      add :trackers, :string, null: false, default: "[]"
    end
  end
end
