defmodule Flux.Torrent.ChokerTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Choker

  test "unchokes only the top-N interested peers by download rate" do
    peers = %{
      a: %{interested: true, download_rate: 100},
      b: %{interested: true, download_rate: 50},
      c: %{interested: true, download_rate: 10},
      d: %{interested: true, download_rate: 1}
    }

    decision = Choker.decide(peers, 2)
    assert decision.a == :unchoke
    assert decision.b == :unchoke
    assert decision.c == :choke
    assert decision.d == :choke
  end

  test "never unchokes a non-interested peer" do
    peers = %{a: %{interested: false, download_rate: 1000}}
    assert Choker.decide(peers, 4) == %{a: :choke}
  end

  test "returns a decision for every peer in the input, including choked ones" do
    peers = %{a: %{interested: true, download_rate: 1}, b: %{interested: false, download_rate: 0}}
    decision = Choker.decide(peers, 4)
    assert map_size(decision) == 2
  end

  test "optimistic unchoke adds exactly one extra interested peer beyond the top-N" do
    peers = %{
      a: %{interested: true, download_rate: 100},
      b: %{interested: true, download_rate: 1},
      c: %{interested: true, download_rate: 1}
    }

    decision = Choker.decide(peers, 1, optimistic?: true)
    unchoked = for {id, :unchoke} <- decision, do: id
    assert length(unchoked) == 2
    assert :a in unchoked
  end

  test "optimistic unchoke is a no-op when there are no extra interested peers" do
    peers = %{a: %{interested: true, download_rate: 100}}
    decision = Choker.decide(peers, 4, optimistic?: true)
    assert decision == %{a: :unchoke}
  end
end
