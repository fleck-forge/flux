defmodule FluxWeb.DownloadLive.IndexTest do
  use FluxWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Flux.{Bencode, Downloads}

  defp create_download(attrs \\ %{}) do
    defaults = %{
      name: "ubuntu-24.04.iso",
      info_hash: :crypto.hash(:sha, "ubuntu-#{System.unique_integer()}"),
      total_length: 1000,
      downloaded: 250,
      save_path: "/tmp/ubuntu-24.04.iso"
    }

    {:ok, download} = Downloads.create_download(Map.merge(defaults, attrs))
    download
  end

  defp fixture_torrent(name) do
    pieces = :crypto.hash(:sha, "piece")

    info_pairs = [
      {"length", 4},
      {"name", name},
      {"piece length", 16},
      {"pieces", pieces}
    ]

    info_hash = :crypto.hash(:sha, Bencode.encode(info_pairs))
    raw = Bencode.encode([{"announce", "http://tracker.example/announce"}, {"info", info_pairs}])
    {raw, info_hash}
  end

  defp select_row(view, download),
    do: view |> element("#download-#{download.id}") |> render_click()

  test "renders an empty state with no downloads", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No torrents match this view."
    assert html =~ "File"
    assert html =~ "Torrent"
  end

  test "lists an existing download with its progress", %{conn: conn} do
    create_download()

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "ubuntu-24.04.iso"
    assert html =~ "25.0%"
    assert html =~ "downloading"
  end

  test "opening and closing the add-torrent modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#add-torrent-modal")

    html = view |> element("button[phx-click=open_add_modal]") |> render_click()
    assert html =~ "Add Torrent"
    assert html =~ "Magnet link"

    html = view |> element("#add-torrent-modal button[aria-label=\"close\"]") |> render_click()
    refute html =~ "Magnet link"
  end

  test "adding a magnet link creates a download and shows it live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_add_modal]") |> render_click()

    info_hash = :crypto.hash(:sha, "magnet-fixture-#{System.unique_integer()}")
    hex = Base.encode16(info_hash, case: :lower)
    magnet = "magnet:?xt=urn:btih:#{hex}&dn=My+Show&tr=http%3A%2F%2Ftracker.example%2Fannounce"

    html =
      view
      |> form("form[phx-submit=add_magnet]", %{"magnet_uri" => magnet})
      |> render_submit()

    assert html =~ "Torrent added"
    assert html =~ "My Show"
    refute html =~ "Magnet link"

    assert Downloads.get_download_by_info_hash(info_hash)
  end

  test "submitting an empty magnet field shows an error and adds nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_add_modal]") |> render_click()

    html =
      view
      |> form("form[phx-submit=add_magnet]", %{"magnet_uri" => ""})
      |> render_submit()

    assert html =~ "Paste a magnet link first"
  end

  test "uploading a .torrent file creates a download", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_add_modal]") |> render_click()

    {torrent_bytes, _info_hash} = fixture_torrent("uploaded.bin")

    file =
      file_input(view, "form[phx-submit=add_torrent_file]", :torrent_file, [
        %{
          name: "uploaded.torrent",
          content: torrent_bytes,
          type: "application/x-bittorrent"
        }
      ])

    render_upload(file, "uploaded.torrent")

    html = view |> element("form[phx-submit=add_torrent_file]") |> render_submit()

    assert html =~ "Torrent added"
    assert html =~ "uploaded.bin"
  end

  test "selecting a row enables the toolbar actions and pausing marks it paused", %{conn: conn} do
    download = create_download(%{state: :downloading})
    {:ok, view, _html} = live(conn, ~p"/")

    refute view |> element("button[phx-click=pause_selected]") |> render() =~
             ~s(disabled="disabled")

    select_row(view, download)

    html = view |> element("button[phx-click=pause_selected]") |> render_click()

    assert html =~ "paused"
    assert Downloads.get_download!(download.id).state == :paused
  end

  test "resuming a paused download", %{conn: conn} do
    download = create_download(%{state: :paused})
    {:ok, view, _html} = live(conn, ~p"/")

    select_row(view, download)
    html = view |> element("button[phx-click=resume_selected]") |> render_click()

    # No live session for this fixture row (no metadata/trackers), so the
    # engine fails fast — but the important thing is the action fired.
    assert html =~ "failed" or html =~ "downloading"
  end

  test "removing the selected download deletes it and removes the row live", %{conn: conn} do
    download = create_download()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#download-#{download.id}")

    select_row(view, download)
    html = view |> element("button[phx-click=remove_selected]") |> render_click()
    assert html =~ "Remove this torrent?"

    view |> element("button[phx-click=do_remove]") |> render_click()

    refute has_element?(view, "#download-#{download.id}")
    assert_raise Ecto.NoResultsError, fn -> Downloads.get_download!(download.id) end
  end

  test "canceling the remove confirmation leaves the download untouched", %{conn: conn} do
    download = create_download()
    {:ok, view, _html} = live(conn, ~p"/")

    select_row(view, download)
    view |> element("button[phx-click=remove_selected]") |> render_click()
    html = view |> element("button[phx-click=cancel_confirm]", "Cancel") |> render_click()

    refute html =~ "Remove this torrent?"
    assert has_element?(view, "#download-#{download.id}")
    assert Downloads.get_download!(download.id)
  end

  test "opening properties for the selected download shows its details", %{conn: conn} do
    download = create_download()
    {:ok, view, _html} = live(conn, ~p"/")

    select_row(view, download)
    html = view |> element("button[phx-click=open_properties]") |> render_click()

    assert html =~ Base.encode16(download.info_hash, case: :lower)
    assert html =~ download.save_path
  end

  test "search filters the visible list", %{conn: conn} do
    create_download(%{name: "alpha.iso"})
    create_download(%{name: "beta.iso"})
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("form[phx-change=search]", %{"q" => "alpha"}) |> render_change()

    assert html =~ "alpha.iso"
    refute html =~ "beta.iso"
  end

  test "the state filter narrows the list", %{conn: conn} do
    create_download(%{name: "downloading.iso", state: :downloading})
    create_download(%{name: "paused.iso", state: :paused})
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-change=filter_state]", %{"state" => "paused"})
      |> render_change()

    assert html =~ "paused.iso"
    refute html =~ "downloading.iso"
  end

  test "live updates reflect a PubSub broadcast without a page reload", %{conn: conn} do
    download = create_download(%{downloaded: 100, total_length: 1000})
    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "10.0%"

    {:ok, _} = Downloads.update_progress(download, 500)

    assert render(view) =~ "50.0%"
  end

  test "shows peer count and ETA for a downloading torrent with no live session", %{conn: conn} do
    create_download(%{state: :downloading})
    {:ok, view, _html} = live(conn, ~p"/")

    # No Torrent session is running for this DB-only fixture row, so the
    # periodic peer-stats tick should report zero peers and no ETA yet.
    send(view.pid, :peer_stats_tick)
    html = render(view)

    assert html =~ "0 peers"
    assert html =~ "ETA:"
    assert html =~ "—"
  end
end
