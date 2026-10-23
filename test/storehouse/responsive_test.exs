defmodule Storehouse.ResponsiveTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Storehouse.{Analysis, Memory, Responsive}
  alias StorehouseTest.Renderers.Counting

  @fixtures Path.expand("../fixtures", __DIR__)
  @presets [
    photo: [widths: [640, 1280, 1920]],
    banner: [widths: [600, 1200], aspect: {3, 1}, fit: :cover],
    thumb: [width: 300, height: 300, fit: :cover]
  ]
  @opts [presets: @presets, adapter: Memory]

  # An image host that answers 200, and tells the test what it was asked.
  defmodule Host do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, test: test) do
      accept = conn |> Plug.Conn.get_req_header("accept") |> Enum.join()
      send(test, {:asked, conn.request_path, accept})
      status = if String.contains?(conn.request_path, "/w:1280/"), do: 500, else: 200
      Plug.Conn.send_resp(conn, status, "")
    end
  end

  setup do
    Memory.checkout()
    {:ok, file} = Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory)
    %{original: file}
  end

  defp sized(width, height),
    do: %Storehouse.File{
      key: "2026/10/x.jpg",
      url: "",
      name: "x.jpg",
      bytes: 1,
      content_type: "image/jpeg",
      width: width,
      height: height
    }

  defp host do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Host, test: self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  describe "widths/3" do
    test "an original narrower than the ladder: its own width, asked at the first step" do
      assert Responsive.widths(sized(300, 200), :photo, @opts) == [{300, 640}]
    end

    test "an original between steps: those below it, then its own, at the step above" do
      assert Responsive.widths(sized(1500, 1000), :photo, @opts) ==
               [{640, 640}, {1280, 1280}, {1500, 1920}]

      assert Responsive.widths(sized(1280, 800), :photo, @opts) == [{640, 640}, {1280, 1280}]
    end

    test "an original wider than the ladder: the ladder" do
      assert Responsive.widths(sized(6000, 4000), :photo, @opts) ==
               [{640, 640}, {1280, 1280}, {1920, 1920}]
    end

    test "an original of no known width: the ladder" do
      assert Responsive.widths(sized(nil, nil), :photo, @opts) ==
               [{640, 640}, {1280, 1280}, {1920, 1920}]
    end
  end

  describe "resolve/3" do
    test "src, srcset and the size of the largest", %{original: file} do
      resolved = Responsive.resolve(file, :photo, Keyword.put(@opts, :sizes, "100vw"))
      url = &Storehouse.variant_url(file, :photo, Keyword.put(@opts, :width, &1))

      assert resolved.srcset == "#{url.(640)} 640w, #{url.(1200)} 1200w"
      assert resolved.src == url.(1280)
      assert resolved.sizes == "100vw"
      assert {resolved.width, resolved.height} == {1200, 800}
    end

    test "a src of the width asked for", %{original: file} do
      resolved = Responsive.resolve(file, :photo, Keyword.put(@opts, :src, 700))

      assert resolved.src ==
               Storehouse.variant_url(file, :photo, Keyword.put(@opts, :width, 1280))
    end

    test "the size of the largest, as the box says" do
      wide = Responsive.resolve(sized(6000, 4000), :photo, @opts)
      assert {wide.width, wide.height} == {1920, 1280}

      banner = Responsive.resolve(sized(6000, 4000), :banner, @opts)
      assert {banner.width, banner.height} == {1200, 400}

      thumb = Responsive.resolve(sized(6000, 4000), :thumb, @opts)
      assert {thumb.width, thumb.height} == {300, 300}
    end

    test "its placeholder, colour and hashes, from its analysis", %{original: file} do
      bare = Responsive.resolve(file, :photo, @opts)
      assert {bare.placeholder, bare.color, bare.thumbhash} == {nil, nil, nil}

      {:ok, file} =
        Storehouse.analyze(
          file,
          [
            Storehouse.Analyzer.Placeholder,
            Storehouse.Analyzer.ThumbHash,
            Storehouse.Analyzer.BlurHash
          ],
          adapter: Memory
        )

      resolved = Responsive.resolve(file, :photo, @opts)
      assert "data:image/webp;base64," <> _ = resolved.placeholder
      assert resolved.color == "#9a7b76"
      assert is_binary(resolved.thumbhash)
      assert is_binary(resolved.blurhash)
    end

    test "as JSON", %{original: file} do
      json =
        file
        |> Responsive.resolve(:photo, @opts)
        |> Storehouse.JSON.encode!()
        |> Storehouse.JSON.decode!()

      assert Map.keys(json) |> Enum.sort() ==
               ~w(blurhash color height placeholder sizes src srcset thumbhash width)

      assert json["width"] == 1200
    end
  end

  test "urls/3: every size once, up to a width", %{original: file} do
    url = &Storehouse.variant_url(file, :photo, Keyword.put(@opts, :width, &1))

    assert Responsive.urls(file, :photo, @opts) == [url.(640), url.(1280)]

    assert Responsive.urls(sized(6000, 4000), :photo, Keyword.put(@opts, :up_to, 1280))
           |> length() == 2
  end

  describe "warm/3" do
    test "in the app, each size made once", %{original: file} do
      opts = Keyword.put(@opts, :renderer, {Counting, test: self()})

      assert {:ok, 2} = Responsive.warm(file, [:photo], opts)
      assert_received {:rendered, _node, :photo, 640}
      assert_received {:rendered, _node, :photo, 1280}

      assert {:ok, 2} = Responsive.warm(file, :photo, opts)
      refute_received {:rendered, _node, _preset, _width}
    end

    test "over HTTP, each URL asked for as a browser asks", %{original: file} do
      base = host()
      renderer = {Storehouse.Renderer.Imgproxy, url: base, source: "s3://photos/"}
      opts = Keyword.merge(@opts, renderer: renderer)

      assert {:error, {:not_warmed, [{{:photo, 1280}, {:status, 500}}]}} =
               Responsive.warm(sized(1500, 1000), :photo, opts)

      assert_received {:asked, "/insecure/w:640/" <> _, accept}
      assert accept =~ "image/avif"
      assert_received {:asked, "/insecure/w:1920/" <> _, _accept}

      assert {:ok, 1} = Responsive.warm(file, :photo, Keyword.put(opts, :up_to, 640))
    end

    test "the app's own URLs, through its host", %{original: file} do
      base = host()

      assert {:error, {:not_warmed, [{{:photo, 640}, {:relative_url, "/variants/" <> _}} | _]}} =
               Responsive.warm(file, :photo, Keyword.put(@opts, :through, :http))

      assert {:ok, 2} =
               Responsive.warm(file, :photo, Keyword.merge(@opts, through: :http, base_url: base))

      assert_received {:asked, "/variants/" <> _, _accept}
    end
  end

  describe "warm_later/3" do
    test "nothing while warming is off", %{original: file} do
      refute Responsive.enabled?()

      opts =
        Keyword.merge(@opts, renderer: {Counting, test: self()}, runner: Storehouse.Runner.Memory)

      assert :ok = Responsive.warm_later(file, [:photo], opts)
      refute_received {:rendered, _node, _preset, _width}
    end

    test "a job of the runner, when it is on", %{original: file} do
      opts =
        Keyword.merge(@opts,
          renderer: {Counting, test: self()},
          runner: Storehouse.Runner.Memory,
          enabled: true
        )

      assert :ok = Responsive.warm_later(file, [:photo], opts)
      assert_received {:rendered, _node, :photo, 640}
      assert_received {:rendered, _node, :photo, 1280}
    end
  end

  describe "Storehouse.Analyzer.Warm" do
    test "skipped while warming is off; the sizes made when it is on", %{original: file} do
      step =
        {Storehouse.Analyzer.Warm,
         Keyword.merge(@opts, warm: [:photo], renderer: {Counting, test: self()})}

      {:ok, off} = Storehouse.analyze(file, [step], adapter: Memory)
      assert Storehouse.File.analysis(off, "warm").status == :skipped

      {name, opts} = step

      {:ok, on} =
        Storehouse.analyze(file, [{name, Keyword.put(opts, :enabled, true)}], adapter: Memory)

      assert Storehouse.File.analyzed(on, "warm") == %{"sizes" => 2}
      assert_received {:rendered, _node, :photo, 1280}
    end
  end

  describe "Storehouse.Components.img/1" do
    test "an img with its sizes, and its placeholder under it", %{original: file} do
      {:ok, file} = Storehouse.analyze(file, [Storehouse.Analyzer.Placeholder], adapter: Memory)
      assigns = %{file: file, opts: @opts}

      html =
        rendered_to_string(~H"""
        <Storehouse.Components.img file={@file} preset={:photo} sizes="100vw" alt="A harbour" options={@opts} />
        """)

      assert html =~ ~s(srcset="#{Responsive.resolve(file, :photo, @opts).srcset}")
      assert html =~ ~s(sizes="100vw")
      assert html =~ ~s(width="1200")
      assert html =~ ~s(height="800")
      assert html =~ ~s(alt="A harbour")
      assert html =~ "background: #9a7b76 url(data:image/webp;base64,"
    end

    test "nothing in its style but a placeholder and a colour", %{original: file} do
      file =
        Storehouse.File.put_analysis(
          file,
          "placeholder",
          Analysis.ok(%{"placeholder" => "javascript:alert(1)", "color" => "red;}"})
        )

      assigns = %{file: file, opts: @opts}

      html =
        rendered_to_string(~H"""
        <Storehouse.Components.img file={@file} preset={:photo} options={@opts} />
        """)

      refute html =~ "style"
      refute html =~ "javascript"
    end
  end
end
