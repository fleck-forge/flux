# Flux

Flux is a torrent client with a native desktop UI on Linux (Ubuntu/Debian),
built with Phoenix LiveView for the interface and SQLite for storage.

The native window is provided by [`desktop`](https://hex.pm/packages/desktop)
(elixir-desktop), which wraps the Phoenix/LiveView app in a real wxWidgets
window (GTK WebView backend on Linux) — there's no browser tab or address bar,
and the whole thing is packageable as a `.deb`.

> Note: LiveView Native (the SwiftUI/Jetpack Compose framework) was
> deliberately **not** used here — it has no Linux desktop renderer. This
> project uses the standard `phoenix_live_view` browser renderer, hosted
> inside a native OS window via `elixir-desktop`.

## Requirements

* Elixir >= 1.15, Erlang/OTP >= 24 (built with `:wx` support)
* SQLite3 (via `ecto_sqlite3` — no separate server to install)

### System packages (Ubuntu/Debian)

```bash
# Runtime (to open the native window)
sudo apt install libwxgtk-webview3.2-1t64 libwxgtk3.2-1t64

# Build tools (compiling NIFs, first-time toolchain setup)
sudo apt install inotify-tools libtool automake libgmp-dev make \
  libwxgtk-webview3.0-gtk3-dev libssl-dev libncurses5-dev curl git
```

(Package names vary a bit across Ubuntu/Debian releases — if
`libwxgtk-webview3.2-1t64` isn't found, try `libwxgtk-webview3.0-gtk3-0v5`.)

## Setup

```bash
mix setup       # deps.get, ecto.create, ecto.migrate, assets
```

## Running

```bash
mix phx.server
```

This opens Flux in its own native window (not a browser). The Phoenix
endpoint itself binds to `127.0.0.1` on a random free port purely as a local
transport for the native WebView — `Desktop.Auth` rejects any request that
doesn't carry the window's per-run auth token, so the endpoint isn't
reachable as a normal web server.

### Headless / no display (dev container, CI)

Opening a real window requires an X server. Either use a virtual one:

```bash
xvfb-run -a mix phx.server
```

or skip the window entirely and run the endpoint alone (useful for quickly
exercising LiveView/Ecto code without a display):

```bash
NO_WX=1 mix phx.server
```

## Database

SQLite, via `Flux.Repo` (`Ecto.Adapters.SQLite3`). Dev/test databases are
plain files (`flux_dev.db`, `flux_test.db`) at the project root; the prod
runtime config (`config/runtime.exs`) defaults to a per-user path
(`~/.local/share/flux/flux.db`, overridable with `DATABASE_PATH`) since an
installed desktop app has no shell to export env vars in.

### `downloads` table

| column        | type                                                | notes                        |
|---------------|-----------------------------------------------------|-------------------------------|
| `id`          | `binary_id` (UUID)                                   | primary key                   |
| `name`        | `string`                                             |                                |
| `info_hash`   | `binary`                                             | unique                        |
| `total_length`| `integer`                                            | bytes                         |
| `downloaded`  | `integer`                                            | bytes, default `0`            |
| `state`       | `string`, mapped to `Ecto.Enum`                      | `downloading`/`paused`/`completed`/`failed` |
| `created_at`  | `utc_datetime`                                       |                                |
| `updated_at`  | `utc_datetime`                                       |                                |

Schema/changeset: `Flux.Downloads.Download`. Context (list/get/create/update
progress/delete): `Flux.Downloads`.

SQLite has no `ALTER TABLE ADD CONSTRAINT`, so `state`/`downloaded`/
`total_length` validity is enforced in the changeset (`Ecto.Enum` +
`validate_number`) rather than as DB-level `CHECK` constraints.

## Project structure

* `lib/flux/` — domain/business logic (`Flux.Downloads` context, `Flux.Repo`)
* `lib/flux_web/` — Phoenix web layer; `FluxWeb.Endpoint` is a `Desktop.Endpoint`
* `lib/flux_web/live/download_live/` — the downloads LiveView UI
* `lib/flux/application.ex` — supervision tree, including the `Desktop.Window`
  child that opens the native window
* `priv/repo/migrations/` — Ecto migrations

## Packaging as a Linux installer

```bash
mix desktop.installer
```

Produces a distributable Linux package (`.deb`/`.AppImage`/`.rpm` depending
on toolchain availability) in the build output directory.

## Adding torrent engine logic

This scaffold covers the app shell, storage, and UI — it does not implement
the BitTorrent wire protocol (peer handshake, piece selection, trackers/DHT,
etc.). That would live as its own OTP supervision subtree under
`Flux.Application` (one worker/`GenServer` per active torrent), driving
`Flux.Downloads.update_progress/2` as pieces complete.
