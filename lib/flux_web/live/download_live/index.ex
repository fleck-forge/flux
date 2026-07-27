defmodule FluxWeb.DownloadLive.Index do
  use FluxWeb, :live_view

  alias Flux.Downloads
  alias Flux.Torrent
  alias Phoenix.LiveView.JS

  @states [:all, :downloading, :paused, :completed, :failed, :checking]
  @peer_stats_interval 2000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Downloads.subscribe()
      schedule_peer_stats_tick()
    end

    socket =
      socket
      |> assign(
        show_add_modal: false,
        show_properties: false,
        confirm: nil,
        selected_id: nil,
        filter_state: :all,
        search_text: "",
        samples: %{},
        peer_stats: %{},
        alt_speed?: false
      )
      |> allow_upload(:torrent_file,
        accept: [".torrent"],
        max_entries: 1,
        max_file_size: 10_000_000
      )
      |> refresh()

    {:ok, socket}
  end

  ## Modal / form events

  @impl true
  def handle_event("open_add_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_modal, true)}
  end

  def handle_event("close_add_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_modal, false)}
  end

  def handle_event("open_properties", _params, socket) do
    {:noreply, assign(socket, :show_properties, true)}
  end

  def handle_event("close_properties", _params, socket) do
    {:noreply, assign(socket, :show_properties, false)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("add_torrent_file", _params, socket) do
    results =
      consume_uploaded_entries(socket, :torrent_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case results do
      [raw_torrent] ->
        add_and_reply(socket, fn -> Torrent.add_torrent_file(raw_torrent, download_dir()) end)

      [] ->
        {:noreply, put_flash(socket, :error, "Choose a .torrent file first")}
    end
  end

  def handle_event("add_magnet", %{"magnet_uri" => uri}, socket) do
    uri = String.trim(uri)

    if uri == "" do
      {:noreply, put_flash(socket, :error, "Paste a magnet link first")}
    else
      add_and_reply(socket, fn -> Torrent.add_magnet(uri, download_dir()) end)
    end
  end

  ## Filter bar

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, socket |> assign(:filter_state, String.to_existing_atom(state)) |> refresh()}
  end

  def handle_event("search", %{"q" => text}, socket) do
    {:noreply, socket |> assign(:search_text, text) |> refresh()}
  end

  ## Selection + toolbar/menu actions (operate on the selected torrent)

  def handle_event("select_row", %{"id" => id}, socket) do
    selected = if socket.assigns.selected_id == id, do: nil, else: id
    {:noreply, assign(socket, :selected_id, selected)}
  end

  def handle_event("resume_selected", _params, socket),
    do: {:noreply, act_selected(socket, &Torrent.resume/1)}

  def handle_event("pause_selected", _params, socket),
    do: {:noreply, act_selected(socket, &Torrent.pause/1)}

  # Uses an in-app confirmation modal rather than the HTML `data-confirm`
  # attribute (which calls the browser's native `window.confirm()`):
  # elixir-desktop's embedded wxWebView doesn't reliably implement that
  # dialog, so a `data-confirm`-gated click can silently do nothing —
  # exactly what happened here (a "Remove" click never reached the server,
  # leaving the row in the database and causing a later re-add to collide
  # on the unique info_hash constraint).
  def handle_event("remove_selected", _params, socket) do
    {:noreply,
     request_confirm(socket, "Remove this torrent? Downloaded files are kept.", "do_remove")}
  end

  def handle_event("remove_selected_and_delete", _params, socket) do
    message = "Remove this torrent and delete its downloaded files? This can't be undone."
    {:noreply, request_confirm(socket, message, "do_remove_delete")}
  end

  def handle_event("do_remove", _params, socket) do
    socket = act_selected(socket, &Torrent.remove(&1, false))
    {:noreply, socket |> assign(selected_id: nil, confirm: nil)}
  end

  def handle_event("do_remove_delete", _params, socket) do
    socket = act_selected(socket, &Torrent.remove(&1, true))
    {:noreply, socket |> assign(selected_id: nil, confirm: nil)}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  ## Menu bar: File > Quit, alt-speed toggle

  def handle_event("quit", _params, socket) do
    if Process.whereis(FluxWindow) do
      Desktop.Window.quit()
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :info, "Quit isn't available outside the desktop app")}
    end
  end

  def handle_event("about", _params, socket) do
    {:noreply,
     put_flash(socket, :info, "Flux — a BitTorrent client built with Phoenix LiveView.")}
  end

  def handle_event("toggle_alt_speed", _params, socket) do
    {:noreply, update(socket, :alt_speed?, &(!&1))}
  end

  defp add_and_reply(socket, fun) do
    case fun.() do
      {:ok, _download_id} ->
        socket =
          socket
          |> assign(:show_add_modal, false)
          |> put_flash(:info, "Torrent added")
          |> refresh()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, add_error_message(reason))}
    end
  end

  defp add_error_message(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :info_hash) do
      "This torrent has already been added."
    else
      errors
      |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
      |> Enum.join(", ")
    end
  end

  defp add_error_message(reason), do: "Could not add torrent: #{inspect(reason)}"

  defp request_confirm(socket, message, event) do
    assign(socket, :confirm, %{message: message, event: event})
  end

  defp act_selected(socket, fun) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        download = Downloads.get_download!(id)

        case fun.(download.info_hash) do
          :ok -> refresh(socket)
          {:error, reason} -> put_flash(socket, :error, "Action failed: #{inspect(reason)}")
        end
    end
  end

  ## PubSub

  @impl true
  def handle_info({:download_added, _id}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:download_updated, id}, socket) do
    case fetch(id) do
      nil ->
        {:noreply, refresh(socket)}

      download ->
        notify_if_completed(download)
        {:noreply, socket |> update_sample(download) |> refresh()}
    end
  end

  def handle_info({:download_removed, id}, socket) do
    socket =
      if socket.assigns.selected_id == id, do: assign(socket, :selected_id, nil), else: socket

    {:noreply, refresh(socket)}
  end

  # Peer count/seeder/leecher stats live only in each Session.Worker's
  # memory (never persisted), so they can't ride the Downloads PubSub
  # broadcasts — poll them on a timer instead. Cheap: a handful of local
  # GenServer calls every couple seconds, not network I/O.
  def handle_info(:peer_stats_tick, socket) do
    schedule_peer_stats_tick()

    peer_stats =
      socket.assigns.all_downloads
      |> Enum.filter(&(&1.state in [:downloading, :checking]))
      |> Map.new(&{&1.id, Torrent.stats(&1.info_hash)})

    {:noreply, assign(socket, :peer_stats, peer_stats)}
  end

  defp schedule_peer_stats_tick,
    do: Process.send_after(self(), :peer_stats_tick, @peer_stats_interval)

  defp fetch(id) do
    Downloads.get_download!(id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp notify_if_completed(%{state: :completed} = download) do
    if pid = Process.whereis(FluxWindow) do
      Desktop.Window.show_notification(pid, "download-#{download.id}",
        type: :info,
        title: "Download complete",
        message: download.name
      )
    end
  catch
    :exit, _ -> :ok
  end

  defp notify_if_completed(_download), do: :ok

  defp update_sample(socket, download) do
    now = System.monotonic_time(:millisecond)
    prev = socket.assigns.samples[download.id]

    rate =
      case prev do
        %{at: at} when now > at ->
          elapsed = (now - at) / 1000

          %{
            down: max((download.downloaded - prev.downloaded) / elapsed, 0),
            up: max((download.uploaded - prev.uploaded) / elapsed, 0)
          }

        _ ->
          %{down: 0, up: 0}
      end

    sample = %{downloaded: download.downloaded, uploaded: download.uploaded, at: now, rate: rate}
    assign(socket, :samples, Map.put(socket.assigns.samples, download.id, sample))
  end

  defp refresh(socket) do
    all = Downloads.list_downloads()

    filtered =
      all
      |> filter_by_state(socket.assigns.filter_state)
      |> filter_by_search(socket.assigns.search_text)

    assign(socket, all_downloads: all, downloads: filtered)
  end

  defp filter_by_state(downloads, :all), do: downloads
  defp filter_by_state(downloads, state), do: Enum.filter(downloads, &(&1.state == state))

  defp filter_by_search(downloads, ""), do: downloads

  defp filter_by_search(downloads, text) do
    text = String.downcase(text)
    Enum.filter(downloads, &String.contains?(String.downcase(&1.name), text))
  end

  defp download_dir do
    Application.get_env(:flux, :torrent, [])[:download_dir] ||
      Path.join(System.tmp_dir!(), "flux_downloads")
  end

  defp selected(assigns) do
    assigns.selected_id && Enum.find(assigns.all_downloads, &(&1.id == assigns.selected_id))
  end

  defp states, do: @states

  defp state_count(downloads, :all), do: length(downloads)
  defp state_count(downloads, state), do: Enum.count(downloads, &(&1.state == state))

  defp global_ratio(downloads) do
    downloaded = Enum.sum(Enum.map(downloads, & &1.downloaded))
    uploaded = Enum.sum(Enum.map(downloads, & &1.uploaded))
    ratio(%{downloaded: downloaded, uploaded: uploaded})
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected, selected(assigns))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col h-screen">
        <.menu_bar />

        <.toolbar selected={@selected} />

        <.filter_bar
          filter_state={@filter_state}
          search_text={@search_text}
          all_downloads={@all_downloads}
        />

        <div class="flex-1 overflow-y-auto">
          <p :if={@downloads == []} class="text-center text-base-content/60 py-16">
            No torrents match this view.
          </p>
          <.torrent_row
            :for={download <- @downloads}
            download={download}
            selected?={@selected_id == download.id}
            rate={Map.get(@samples, download.id, %{rate: %{down: 0, up: 0}}).rate}
            peer_stats={Map.get(@peer_stats, download.id)}
          />
        </div>

        <.status_bar all_downloads={@all_downloads} alt_speed?={@alt_speed?} />
      </div>

      <.modal id="add-torrent-modal" show={@show_add_modal} on_close="close_add_modal">
        <h2 class="text-lg font-semibold mb-4">Add Torrent</h2>

        <form phx-submit="add_torrent_file" phx-change="validate_upload" class="mb-6">
          <label class="label mb-1">.torrent file</label>
          <.live_file_input upload={@uploads.torrent_file} class="file-input w-full" />
          <div :for={err <- upload_errors(@uploads.torrent_file)} class="text-sm text-error mt-1">
            {error_to_string(err)}
          </div>
          <.button type="submit" variant="primary" class="mt-3">Upload &amp; Add</.button>
        </form>

        <div class="divider">or</div>

        <form phx-submit="add_magnet">
          <label class="label mb-1">Magnet link</label>
          <input
            type="text"
            name="magnet_uri"
            placeholder="magnet:?xt=urn:btih:..."
            class="w-full input"
          />
          <.button type="submit" variant="primary" class="mt-3">Add Magnet</.button>
        </form>
      </.modal>

      <.modal
        id="properties-modal"
        show={@show_properties and @selected != nil}
        on_close="close_properties"
      >
        <.properties_content
          :if={@selected}
          download={@selected}
          peer_stats={Map.get(@peer_stats, @selected.id)}
          rate={Map.get(@samples, @selected.id, %{rate: %{down: 0, up: 0}}).rate}
        />
      </.modal>

      <.modal id="confirm-modal" show={@confirm != nil} on_close="cancel_confirm">
        <div :if={@confirm}>
          <p class="mb-4">{@confirm.message}</p>
          <div class="flex justify-end gap-2">
            <.button phx-click="cancel_confirm">Cancel</.button>
            <.button phx-click={@confirm.event} variant="primary">Confirm</.button>
          </div>
        </div>
      </.modal>
    </Layouts.app>
    """
  end

  ## Menu bar

  defp menu_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-1 border-b border-base-300 px-1 text-sm bg-base-100">
      <.menu label="File">
        <.menu_item phx-click="open_add_modal">Open…</.menu_item>
        <li class="divider my-0"></li>
        <.menu_item phx-click="quit">Quit</.menu_item>
      </.menu>
      <.menu label="Edit">
        <.menu_item disabled>Preferences…</.menu_item>
      </.menu>
      <.menu label="Torrent">
        <.menu_item phx-click="resume_selected">Play</.menu_item>
        <.menu_item phx-click="pause_selected">Pause</.menu_item>
        <li class="divider my-0"></li>
        <.menu_item phx-click="remove_selected">Remove</.menu_item>
        <.menu_item phx-click="remove_selected_and_delete">Remove and Delete Files…</.menu_item>
        <li class="divider my-0"></li>
        <.menu_item phx-click="open_properties">Properties…</.menu_item>
      </.menu>
      <.menu label="View">
        <.menu_item phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="system">
          System theme
        </.menu_item>
        <.menu_item phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light">
          Light theme
        </.menu_item>
        <.menu_item phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark">
          Dark theme
        </.menu_item>
      </.menu>
      <.menu label="Help">
        <.menu_item phx-click="about">About Flux</.menu_item>
      </.menu>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp menu(assigns) do
    ~H"""
    <div class="dropdown">
      <div tabindex="0" role="button" class="btn btn-ghost btn-xs rounded-none px-2 font-normal">
        {@label}
      </div>
      <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-20 w-56 p-2 shadow">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  defp menu_item(assigns) do
    ~H"""
    <li>
      <a
        class={@disabled && "disabled pointer-events-none opacity-40"}
        aria-disabled={@disabled}
        {@rest}
      >
        {render_slot(@inner_block)}
      </a>
    </li>
    """
  end

  ## Toolbar

  attr :selected, :map, default: nil

  defp toolbar(assigns) do
    ~H"""
    <div class="flex items-center gap-1 border-b border-base-300 px-2 py-1.5 bg-base-100">
      <.toolbar_button phx-click="open_add_modal" label="Open" icon="hero-arrow-up-tray" />
      <.toolbar_button
        phx-click="resume_selected"
        label="Resume"
        icon="hero-play"
        disabled={is_nil(@selected) or @selected.state not in [:paused, :failed]}
      />
      <.toolbar_button
        phx-click="pause_selected"
        label="Pause"
        icon="hero-pause"
        disabled={is_nil(@selected) or @selected.state not in [:downloading, :checking]}
      />
      <div class="divider divider-horizontal mx-0"></div>
      <.toolbar_button
        phx-click="remove_selected"
        label="Remove"
        icon="hero-minus-circle"
        disabled={is_nil(@selected)}
      />
      <div class="flex-1"></div>
      <.toolbar_button
        phx-click="open_properties"
        label="Properties"
        icon="hero-information-circle"
        disabled={is_nil(@selected)}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :disabled, :boolean, default: false
  attr :rest, :global

  defp toolbar_button(assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-ghost btn-sm h-auto flex-col gap-0.5 rounded-none px-3 py-1 disabled:opacity-30"
      disabled={@disabled}
      {@rest}
    >
      <.icon name={@icon} class="size-5" />
      <span class="text-[11px] font-normal">{@label}</span>
    </button>
    """
  end

  ## Filter bar

  attr :filter_state, :atom, required: true
  attr :search_text, :string, required: true
  attr :all_downloads, :list, required: true

  defp filter_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-base-300 px-2 py-1.5 bg-base-100">
      <span class="text-sm text-base-content/70">Show:</span>
      <form phx-change="filter_state">
        <select name="state" class="select select-sm w-40">
          <option :for={s <- states()} value={s} selected={s == @filter_state}>
            {String.capitalize(to_string(s))} ({state_count(@all_downloads, s)})
          </option>
        </select>
      </form>

      <select class="select select-sm w-32" disabled>
        <option>All</option>
      </select>

      <div class="flex-1"></div>

      <form phx-change="search" class="flex items-center">
        <label class="input input-sm flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
          <input
            type="text"
            name="q"
            value={@search_text}
            placeholder="Filter torrents…"
            class="grow"
          />
        </label>
      </form>
    </div>
    """
  end

  ## List rows

  attr :download, :map, required: true
  attr :selected?, :boolean, required: true
  attr :rate, :map, required: true
  attr :peer_stats, :map, default: nil

  defp torrent_row(assigns) do
    ~H"""
    <div
      id={"download-#{@download.id}"}
      phx-click="select_row"
      phx-value-id={@download.id}
      class={[
        "flex items-start gap-3 px-3 py-2 border-b border-base-200 cursor-pointer",
        @selected? && "bg-primary/10"
      ]}
    >
      <.icon name="hero-archive-box" class="size-8 shrink-0 opacity-70 mt-0.5" />
      <div class="min-w-0 flex-1">
        <div class="font-medium truncate">{@download.name}</div>
        <div class="text-xs text-base-content/60">
          {format_bytes(@download.total_length)}, uploaded {format_bytes(@download.uploaded)} (Ratio: {ratio(
            @download
          )})
        </div>
        <progress
          class={["progress w-full h-1.5 mt-1", progress_color(@download.state)]}
          value={@download.downloaded}
          max={max(@download.total_length, 1)}
        />
        <div class="text-xs text-base-content/60 mt-0.5 flex items-center gap-2">
          <span class={["badge badge-xs", state_badge_class(@download.state)]}>
            {state_label(@download)}
          </span>
          <span>{progress_percent(@download)}%</span>
          <span :if={@download.state == :downloading}>
            ↓ {format_rate(@rate.down)} · ↑ {format_rate(@rate.up)}
          </span>
          <span :if={@download.state == :downloading}>
            {peer_count_text(@peer_stats)}
          </span>
          <span :if={@download.state == :downloading}>
            ETA: {format_eta(eta_seconds(@download, @rate))}
          </span>
          <span :if={@download.error_message} class="text-error">{@download.error_message}</span>
        </div>
      </div>
    </div>
    """
  end

  ## Properties panel

  attr :download, :map, required: true
  attr :peer_stats, :map, default: nil
  attr :rate, :map, required: true

  defp properties_content(assigns) do
    ~H"""
    <h2 class="text-lg font-semibold mb-4 truncate">{@download.name}</h2>
    <.list>
      <:item title="State">{state_label(@download)}</:item>
      <:item :if={@download.state == :completed and @download.verified_from_disk} title="Note">
        Found already complete at the save location — verified against the
        torrent's piece hashes, nothing was downloaded this session.
      </:item>
      <:item :if={@download.state == :downloading} title="Peers">
        {peer_count_text(@peer_stats)}
      </:item>
      <:item :if={@download.state == :downloading} title="ETA">
        {format_eta(eta_seconds(@download, @rate))}
      </:item>
      <:item title="Size">{format_bytes(@download.total_length)}</:item>
      <:item title="Downloaded">{format_bytes(@download.downloaded)}</:item>
      <:item title="Uploaded">{format_bytes(@download.uploaded)}</:item>
      <:item title="Ratio">{ratio(@download)}</:item>
      <:item title="Save path">{@download.save_path}</:item>
      <:item title="Info hash">{Base.encode16(@download.info_hash, case: :lower)}</:item>
      <:item :if={@download.magnet_uri} title="Magnet">{@download.magnet_uri}</:item>
      <:item title="Trackers">{trackers_summary(@download.trackers)}</:item>
      <:item :if={@download.error_message} title="Error">{@download.error_message}</:item>
    </.list>
    """
  end

  defp trackers_summary(json) do
    case Jason.decode(json || "[]") do
      {:ok, tiers} when is_list(tiers) -> tiers |> List.flatten() |> Enum.join(", ")
      _ -> "—"
    end
  end

  ## Status bar

  attr :all_downloads, :list, required: true
  attr :alt_speed?, :boolean, required: true

  defp status_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-t border-base-300 px-3 py-1.5 bg-base-100 text-sm">
      <button
        type="button"
        phx-click="toggle_alt_speed"
        class={["btn btn-ghost btn-xs", @alt_speed? && "text-primary"]}
        title="Alternative speed limits"
      >
        <.icon name="hero-bolt-slash" class="size-4" />
      </button>
      <.icon name="hero-signal" class="size-4 opacity-50" />
      <div class="flex-1"></div>
      <span class="text-base-content/70">Ratio: {global_ratio(@all_downloads)}</span>
    </div>
    """
  end

  defp progress_percent(%{total_length: 0}), do: 0

  defp progress_percent(%{downloaded: downloaded, total_length: total_length}) do
    Float.round(downloaded / total_length * 100, 1)
  end

  defp progress_color(:completed), do: "progress-success"
  defp progress_color(:failed), do: "progress-error"
  defp progress_color(_), do: "progress-primary"

  defp state_badge_class(:downloading), do: "badge-info"
  defp state_badge_class(:paused), do: "badge-warning"
  defp state_badge_class(:completed), do: "badge-success"
  defp state_badge_class(:failed), do: "badge-error"
  defp state_badge_class(:checking), do: "badge-neutral"

  # A download that reached :completed via initial disk verification (the
  # file was already fully intact at save_path) never actually transferred
  # anything through this session — labeled distinctly so it doesn't read
  # as a multi-GB file that impossibly finished in seconds.
  defp state_label(%{state: :completed, verified_from_disk: true}), do: "already on disk"
  defp state_label(%{state: state}), do: state

  defp ratio(%{downloaded: 0, uploaded: 0}), do: "0.00"
  defp ratio(%{downloaded: 0}), do: "∞"

  defp ratio(download) do
    :erlang.float_to_binary(download.uploaded / download.downloaded, decimals: 2)
  end

  defp format_rate(bytes_per_sec), do: "#{format_bytes(round(bytes_per_sec))}/s"

  defp peer_count_text(nil), do: "0 peers"

  defp peer_count_text(%{peer_count: count, tracker_seeders: s, tracker_leechers: l}) do
    case {s, l} do
      {nil, nil} -> "#{count} #{pluralize(count, "peer")}"
      _ -> "#{count} #{pluralize(count, "peer")} (#{s || 0} seeds, #{l || 0} leech)"
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  # Estimated time remaining, derived from the same live download-rate
  # sample used for the speed display — no extra engine state needed.
  # `nil` (rendered as "—") means "can't estimate yet" (not moving, or
  # already done), not "instant".
  defp eta_seconds(%{state: state}, _rate) when state != :downloading, do: nil

  defp eta_seconds(download, %{down: rate}) when rate > 0 do
    remaining = max(download.total_length - download.downloaded, 0)
    round(remaining / rate)
  end

  defp eta_seconds(_download, _rate), do: nil

  defp format_eta(nil), do: "—"
  defp format_eta(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_eta(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp format_eta(seconds) when seconds < 86_400 do
    "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  end

  defp format_eta(seconds), do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) do
    {value, unit} = scale_bytes(bytes / 1024, ["KB", "MB", "GB", "TB"])
    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  defp scale_bytes(value, [unit]), do: {value, unit}
  defp scale_bytes(value, [unit | _rest]) when value < 1024, do: {value, unit}
  defp scale_bytes(value, [_unit | rest]), do: scale_bytes(value / 1024, rest)

  defp error_to_string(:too_large), do: "File is too large"
  defp error_to_string(:not_accepted), do: "Only .torrent files are accepted"
  defp error_to_string(:too_many_files), do: "Only one file at a time"
  defp error_to_string(other), do: to_string(other)
end
