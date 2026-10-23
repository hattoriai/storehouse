defmodule Storehouse.ImgproxyTest do
  use ExUnit.Case, async: true

  alias Storehouse.Renderer.Imgproxy

  # A key and a salt of imgproxy's documentation.
  @key "943b421c9eb07c830af81030552c86009268de4e532ba2ee2eab8247c6da0881"
  @salt "520f986b998545b4785e0defbc4f3c1203f22de2374a3d53cb7a7fe9fea309c5"

  @file_ %Storehouse.File{
    key: "uploads/0b6/harbour.jpg",
    url: "/uploads/0b6/harbour.jpg",
    name: "harbour.jpg",
    bytes: 1,
    content_type: "image/jpeg"
  }

  defp url(preset, opts \\ []) do
    {renderer_opts, opts} = Keyword.split(opts, [:key, :salt, :source, :extension])

    renderer =
      {Imgproxy,
       Keyword.merge([url: "https://images.example.com/", source: "s3://photos/"], renderer_opts)}

    Storehouse.variant_url(
      @file_,
      :p,
      Keyword.merge([presets: [p: preset], renderer: renderer], opts)
    )
  end

  defp source(key \\ "uploads/0b6/harbour.jpg"),
    do: Base.url_encode64("s3://photos/" <> key, padding: false)

  test "signed as imgproxy checks it: HMAC-SHA256 of the salt and the path" do
    path = "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png"

    assert Imgproxy.signed_path(path, key: @key, salt: @salt) ==
             "/90UxdwGRAI2bpLSHKkZculJau5ahfxfS0h3fMuQAf40" <> path
  end

  test "unsigned without a key, for development" do
    assert url(width: 320) == "https://images.example.com/insecure/w:320/#{source()}"
  end

  test "a key and a salt, together" do
    assert_raise ArgumentError, ~r/together/, fn -> url([width: 320], key: @key) end
  end

  test "a preset as imgproxy's options" do
    for {preset, options} <- [
          {[width: 320, height: 200], "rs:fit:320:200"},
          {[width: 320, height: 200, fit: :cover], "rs:fill:320:200/g:ce"},
          {[width: 320, height: 200, fit: :cover, focus: :attention], "rs:fill:320:200/g:sm"},
          {[width: 320, aspect: {16, 9}, fit: :cover, focus: {0.25, 1}],
           "rs:fill:320:180/g:fp:0.25:1.0"},
          {[width: 320, quality: 70, format: :webp], "w:320/q:70/f:webp"},
          {[width: 320, format: :jpeg, background: "#1A1A1A"], "w:320/f:jpg/bg:1A1A1A"},
          {[width: 320, format: [:avif, :webp, :original]], "w:320"},
          {[width: 320, metadata: :all], "w:320/sm:0"}
        ] do
      assert url(preset) == "https://images.example.com/insecure/#{options}/#{source()}"
    end
  end

  test "a width of a ladder, as asked" do
    assert url([widths: [640, 1280, 1920]], width: 1000) =~ "/w:1280/"
  end

  test "a photograph's own focus, signed with it" do
    preset = [width: 600, height: 315, fit: :cover]
    assert url(preset, focus: {0.3, 0.6}) =~ "/rs:fill:600:315/g:fp:0.3:0.6/"
  end

  test "the format as an extension" do
    assert url([width: 320, format: :webp], extension: true) ==
             "https://images.example.com/insecure/w:320/#{source()}.webp"

    assert url([width: 320], extension: true) ==
             "https://images.example.com/insecure/w:320/#{source()}"
  end

  test "where imgproxy reads the original" do
    assert url([width: 320], source: &"https://files.example.com/#{&1.key}") =~
             Base.url_encode64("https://files.example.com/uploads/0b6/harbour.jpg",
               padding: false
             )
  end

  # What indie.camera's Worker signs for a photograph's short address
  # (`/p/<site>/<file>/1280`): the same path, so a size rendered for one is
  # found for the other.
  test "a wide-gamut photograph at a fidelity of its own" do
    file = %{
      @file_
      | key:
          "uploads/0193a0b1-0000-7000-8000-000000000001/0193a0b1-0000-7000-8000-000000000002.jpg"
    }

    preset = [
      widths: [640, 960, 1280, 1920, 2560, 3840, 7680],
      profile: :keep,
      options: [imgproxy: "fq:webp:86:jpeg:90"]
    ]

    renderer =
      {Imgproxy,
       url: "https://images.example.com", source: "s3://photos/", key: @key, salt: @salt}

    assert Storehouse.variant_url(file, :p, presets: [p: preset], renderer: renderer, width: 1200) ==
             "https://images.example.com/6TSUum_jTIDAKukUGg_AUSqjO9mFI-T4FI3Jb-FFcow/w:1280/scp:0/fq:webp:86:jpeg:90/" <>
               "czM6Ly9waG90b3MvdXBsb2Fkcy8wMTkzYTBiMS0wMDAwLTcwMDAtODAwMC0wMDAwMDAwMDAwMDEvMDE5M2EwYjEtMDAwMC03MDAwLTgwMDAtMDAwMDAwMDAwMDAyLmpwZw"
  end

  test "nothing rendered or stored in the app" do
    renderer = {Imgproxy, url: "https://images.example.com", source: "s3://photos/"}

    assert {:error, :not_supported} =
             Storehouse.variant(@file_, :p, presets: [p: [width: 320]], renderer: renderer)
  end
end
