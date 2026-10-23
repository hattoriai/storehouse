defmodule Storehouse.JSONTest do
  # The library is application config.
  use ExUnit.Case, async: false

  test "encodes and decodes, as Elixir's JSON" do
    data = %{"caption" => "The quay", "sizes" => [640, 1280], "kept" => true, "none" => nil}

    assert data |> Storehouse.JSON.encode!() |> Storehouse.JSON.decode!() == data

    assert IO.iodata_to_binary(Storehouse.JSON.encode_to_iodata!(data)) ==
             Storehouse.JSON.encode!(data)

    assert {:error, _reason} = Storehouse.JSON.decode("{not json")
  end

  test "the app chooses the library" do
    default = Storehouse.JSON.library()
    assert default == if(Code.ensure_loaded?(JSON), do: JSON, else: Jason)

    Application.put_env(:storehouse, :json_library, Jason)
    on_exit(fn -> Application.delete_env(:storehouse, :json_library) end)

    assert Storehouse.JSON.library() == Jason
    assert Storehouse.JSON.decode!(Storehouse.JSON.encode!(%{"a" => 1})) == %{"a" => 1}
  end

  test "the rest of Storehouse names no JSON library" do
    for path <- Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__)),
        Path.basename(path) != "json.ex",
        line <- File.stream!(path),
        # The encoders of Storehouse.File are protocols, not calls.
        not String.contains?(line, ["JSON.Encoder", "Jason.Encode"]) do
      refute line =~ ~r/(?<![.\w])(JSON|Jason)\.(encode|decode)/, "#{path}: #{line}"
    end
  end
end
