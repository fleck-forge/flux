defmodule FluxWeb.DownloadLive.IndexTest do
  use FluxWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Flux.Downloads

  test "renders an empty state with no downloads", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No downloads yet."
  end

  test "lists an existing download with its progress", %{conn: conn} do
    {:ok, _download} =
      Downloads.create_download(%{
        name: "ubuntu-24.04.iso",
        info_hash: :crypto.hash(:sha, "ubuntu"),
        total_length: 1000,
        downloaded: 250,
        save_path: "/tmp/ubuntu-24.04.iso"
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "ubuntu-24.04.iso"
    assert html =~ "25.0%"
    assert html =~ "downloading"
  end
end
