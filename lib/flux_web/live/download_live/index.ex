defmodule FluxWeb.DownloadLive.Index do
  use FluxWeb, :live_view

  alias Flux.Downloads

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :downloads, Downloads.list_downloads())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <h1 class="text-2xl font-bold mb-4">Downloads</h1>

      <table :if={@downloads != []} class="w-full text-left border-collapse">
        <thead>
          <tr class="border-b">
            <th class="py-2">Name</th>
            <th class="py-2">Progress</th>
            <th class="py-2">State</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={download <- @downloads} id={"download-#{download.id}"} class="border-b">
            <td class="py-2">{download.name}</td>
            <td class="py-2">{progress_percent(download)}%</td>
            <td class="py-2">{download.state}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@downloads == []} class="text-gray-500">No downloads yet.</p>
    </div>
    """
  end

  defp progress_percent(%{total_length: 0}), do: 0

  defp progress_percent(%{downloaded: downloaded, total_length: total_length}) do
    Float.round(downloaded / total_length * 100, 1)
  end
end
