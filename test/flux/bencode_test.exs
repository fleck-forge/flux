defmodule Flux.BencodeTest do
  use ExUnit.Case, async: true

  alias Flux.Bencode

  describe "decode/1 — integers" do
    test "decodes positive and negative integers" do
      assert Bencode.decode("i42e") == {:ok, 42, ""}
      assert Bencode.decode("i-42e") == {:ok, -42, ""}
      assert Bencode.decode("i0e") == {:ok, 0, ""}
    end

    test "leaves trailing bytes in rest" do
      assert Bencode.decode("i42eXYZ") == {:ok, 42, "XYZ"}
    end

    test "rejects leading zeros" do
      assert {:error, _} = Bencode.decode("i03e")
    end

    test "rejects negative zero" do
      assert {:error, _} = Bencode.decode("i-0e")
    end

    test "rejects unterminated integer" do
      assert {:error, _} = Bencode.decode("i42")
    end

    test "rejects non-digit content" do
      assert {:error, _} = Bencode.decode("i4a2e")
    end
  end

  describe "decode/1 — strings" do
    test "decodes a byte string" do
      assert Bencode.decode("4:spam") == {:ok, "spam", ""}
    end

    test "decodes an empty string" do
      assert Bencode.decode("0:") == {:ok, "", ""}
    end

    test "leaves trailing bytes in rest" do
      assert Bencode.decode("4:spamrest") == {:ok, "spam", "rest"}
    end

    test "handles raw binary content (non-UTF8)" do
      bin = <<0, 1, 2, 255>>
      encoded = "4:" <> bin
      assert Bencode.decode(encoded) == {:ok, bin, ""}
    end

    test "rejects a string shorter than its declared length" do
      assert {:error, _} = Bencode.decode("10:short")
    end

    test "rejects invalid length" do
      assert {:error, _} = Bencode.decode("x:spam")
    end
  end

  describe "decode/1 — lists" do
    test "decodes an empty list" do
      assert Bencode.decode("le") == {:ok, [], ""}
    end

    test "decodes a list of mixed types" do
      assert Bencode.decode("l4:spami42ee") == {:ok, ["spam", 42], ""}
    end

    test "decodes nested lists" do
      assert Bencode.decode("ll4:spamee") == {:ok, [["spam"]], ""}
    end
  end

  describe "decode/1 — dicts" do
    test "decodes an empty dict" do
      assert Bencode.decode("de") == {:ok, [], ""}
    end

    test "decodes a dict, preserving wire order of keys as {key, value} pairs" do
      assert Bencode.decode("d3:cow3:moo4:spam4:eggse") ==
               {:ok, [{"cow", "moo"}, {"spam", "eggs"}], ""}
    end

    test "decodes a nested dict" do
      encoded = "d4:infod4:name4:teste5:otheri1ee"
      assert {:ok, [{"info", [{"name", "test"}]}, {"other", 1}], ""} = Bencode.decode(encoded)
    end
  end

  describe "decode_full/1" do
    test "errors on trailing data" do
      assert {:error, :trailing_data} = Bencode.decode_full("i1eextra")
    end

    test "succeeds when the whole binary is consumed" do
      assert {:ok, 1} = Bencode.decode_full("i1e")
    end
  end

  describe "encode/1" do
    test "encodes integers" do
      assert Bencode.encode(42) == "i42e"
      assert Bencode.encode(-42) == "i-42e"
      assert Bencode.encode(0) == "i0e"
    end

    test "encodes strings" do
      assert Bencode.encode("spam") == "4:spam"
      assert Bencode.encode("") == "0:"
    end

    test "encodes lists" do
      assert Bencode.encode(["spam", 42]) == "l4:spami42ee"
      assert Bencode.encode([]) == "le"
    end

    test "encodes dicts sorted by key" do
      assert Bencode.encode([{"spam", "eggs"}, {"cow", "moo"}]) == "d3:cow3:moo4:spam4:eggse"
    end
  end

  describe "round-tripping" do
    test "encode then decode returns the original value for canonical inputs" do
      for value <- [0, 42, -42, "hello", [1, 2, 3], [{"a", 1}, {"b", "two"}]] do
        encoded = Bencode.encode(value)
        assert {:ok, ^value, ""} = Bencode.decode(encoded)
      end
    end
  end

  describe "byte-span derivation via {value, rest} contract" do
    test "byte_size difference between input and rest equals bytes consumed" do
      input = "i42e" <> "4:spam"
      {:ok, 42, rest} = Bencode.decode(input)
      consumed = byte_size(input) - byte_size(rest)
      assert consumed == 4
      assert binary_part(input, 0, consumed) == "i42e"
    end

    test "supports slicing the raw span of a dict value found while walking entries manually" do
      # Simulates what Flux.Torrent.MetaInfo does to capture the raw "info" span.
      raw = "d4:name4:test4:infod6:lengthi100eee"
      {:ok, [_ | _], ""} = Bencode.decode(raw)

      # Manually walk: "name" -> "test", then "info" -> nested dict.
      after_d = String.slice(raw, 1..-1//1)
      {:ok, "name", after_key1} = Bencode.decode(after_d)
      {:ok, "test", after_value1} = Bencode.decode(after_key1)
      {:ok, "info", after_key2} = Bencode.decode(after_value1)
      {:ok, info_value, after_value2} = Bencode.decode(after_key2)

      raw_info_bytes =
        binary_part(after_key2, 0, byte_size(after_key2) - byte_size(after_value2))

      assert info_value == [{"length", 100}]
      assert raw_info_bytes == "d6:lengthi100ee"
    end
  end
end
