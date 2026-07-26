defmodule Flux.Torrent.MagnetTest do
  use ExUnit.Case, async: true

  alias Flux.Torrent.Magnet

  @hash_bytes :crypto.hash(:sha, "hello world")
  @hash_hex Base.encode16(@hash_bytes, case: :lower)

  test "parses a magnet URI with a hex btih, name, and a single tracker" do
    uri =
      "magnet:?xt=urn:btih:#{@hash_hex}&dn=My+Movie&tr=http%3A%2F%2Ftracker.example%2Fannounce"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.info_hash == @hash_bytes
    assert magnet.name == "My Movie"
    assert magnet.trackers == ["http://tracker.example/announce"]
  end

  test "collects multiple tr= params in order" do
    uri = "magnet:?xt=urn:btih:#{@hash_hex}&tr=http%3A%2F%2Fa&tr=http%3A%2F%2Fb"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.trackers == ["http://a", "http://b"]
  end

  test "supports uppercase hex btih" do
    uri = "magnet:?xt=urn:btih:#{String.upcase(@hash_hex)}"
    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.info_hash == @hash_bytes
  end

  test "supports base32 btih encoding" do
    base32_hash = Base.encode32(@hash_bytes, case: :upper, padding: false)
    uri = "magnet:?xt=urn:btih:#{base32_hash}"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.info_hash == @hash_bytes
  end

  test "name defaults to nil when dn is absent" do
    uri = "magnet:?xt=urn:btih:#{@hash_hex}"
    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.name == nil
    assert magnet.trackers == []
  end

  test "errors when xt/btih is missing" do
    assert {:error, :missing_btih} = Magnet.parse("magnet:?dn=no-hash")
  end

  test "errors when btih is malformed" do
    assert {:error, :invalid_btih} = Magnet.parse("magnet:?xt=urn:btih:not-valid")
  end

  test "errors on a non-magnet URI" do
    assert {:error, :not_a_magnet_uri} = Magnet.parse("http://example.com")
  end
end
