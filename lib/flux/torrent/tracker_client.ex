defmodule Flux.Torrent.TrackerClient do
  @moduledoc """
  Behaviour + scheme-based dispatch for tracker announces, so
  `Flux.Torrent.Session.Worker` doesn't need to care whether a given
  tracker URL is `http(s)://` (BEP 3) or `udp://` (BEP 15) — both return the
  same shape.
  """

  @type params :: %{
          required(:info_hash) => binary(),
          required(:peer_id) => binary(),
          required(:port) => non_neg_integer(),
          required(:uploaded) => non_neg_integer(),
          required(:downloaded) => non_neg_integer(),
          required(:left) => integer(),
          optional(:event) => :started | :stopped | :completed | nil,
          optional(:numwant) => integer()
        }

  @type announce_result :: %{
          interval: pos_integer(),
          peers: [{:inet.ip4_address(), :inet.port_number()}],
          seeders: non_neg_integer() | nil,
          leechers: non_neg_integer() | nil
        }

  @callback announce(String.t(), params(), keyword()) ::
              {:ok, announce_result()} | {:error, term()}

  @doc "Dispatches to the HTTP or UDP tracker client based on `tracker_url`'s scheme."
  @spec dispatch(String.t(), params(), keyword()) :: {:ok, announce_result()} | {:error, term()}
  def dispatch(tracker_url, params, opts \\ []) do
    case URI.parse(tracker_url).scheme do
      scheme when scheme in ["http", "https"] ->
        Flux.Torrent.TrackerClient.Http.announce(tracker_url, params, opts)

      "udp" ->
        Flux.Torrent.TrackerClient.Udp.announce(tracker_url, params, opts)

      other ->
        {:error, {:unsupported_tracker_scheme, other}}
    end
  end

  @doc "Decodes BEP 23 compact peer list bytes (6 bytes/peer: 4-byte IP + 2-byte port)."
  @spec parse_compact_peers(binary()) :: [{:inet.ip4_address(), :inet.port_number()}]
  def parse_compact_peers(bin) when is_binary(bin) and rem(byte_size(bin), 6) == 0 do
    for <<a, b, c, d, port::16 <- bin>>, do: {{a, b, c, d}, port}
  end

  def parse_compact_peers(_), do: []
end
