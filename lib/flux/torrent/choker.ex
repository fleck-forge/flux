defmodule Flux.Torrent.Choker do
  @moduledoc """
  Pure choke/unchoke decision function, invoked by
  `Flux.Torrent.Session.Worker` on a timer (every ~10s, per BEP 3
  convention). v1 keeps this simple: unchoke the top-N interested peers by
  the download rate they've given us, plus one periodic optimistic unchoke
  of a random interested peer (to discover better peers over time), and
  choke everyone else.
  """

  @default_unchoke_slots 4

  @type peer_state :: %{interested: boolean(), download_rate: number()}

  @doc """
  Given `%{peer_id => peer_state}`, returns `%{peer_id => :choke | :unchoke}`
  for every peer. Pass `optimistic?: true` (e.g. every 3rd tick) to also
  unchoke one additional random interested peer beyond the top-N.
  """
  @spec decide(%{term() => peer_state()}, pos_integer(), keyword()) :: %{
          term() => :choke | :unchoke
        }
  def decide(peers_state, unchoke_slots \\ @default_unchoke_slots, opts \\ []) do
    interested = for {id, %{interested: true} = s} <- peers_state, do: {id, s}

    top_ids =
      interested
      |> Enum.sort_by(fn {_id, s} -> -s.download_rate end)
      |> Enum.take(unchoke_slots)
      |> Enum.map(fn {id, _s} -> id end)
      |> MapSet.new()

    unchoked_ids =
      if Keyword.get(opts, :optimistic?, false) do
        maybe_add_optimistic(top_ids, interested)
      else
        top_ids
      end

    for {id, _state} <- peers_state, into: %{} do
      {id, if(MapSet.member?(unchoked_ids, id), do: :unchoke, else: :choke)}
    end
  end

  defp maybe_add_optimistic(top_ids, interested) do
    candidates = for {id, _} <- interested, not MapSet.member?(top_ids, id), do: id

    case candidates do
      [] -> top_ids
      list -> MapSet.put(top_ids, Enum.random(list))
    end
  end
end
