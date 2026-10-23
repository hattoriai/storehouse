defmodule Storehouse.PurgeTest do
  # Storehouse.Purge's configuration is the app's: these run one at a time.
  use ExUnit.Case, async: false

  alias Storehouse.{Memory, Purge}

  @fixtures Path.expand("../fixtures", __DIR__)

  # Cloudflare's purge_cache, telling the test each request.
  defmodule Cloudflare do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, test: test) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      auth = conn |> Plug.Conn.get_req_header("authorization") |> Enum.join()
      send(test, {:cloudflare, conn.request_path, auth, Storehouse.JSON.decode!(body)})
      status = if String.contains?(body, "fail"), do: 400, else: 200
      Plug.Conn.send_resp(conn, status, ~s({"success": #{status == 200}}))
    end
  end

  setup do
    Memory.checkout()

    Application.put_env(:storehouse, Purge,
      purger: {StorehouseTest.Purger, test: self()},
      base_url: "https://cdn.example.com",
      urls: &["https://example.com/files/#{&1}"]
    )

    Application.put_env(:storehouse, Storehouse.Variants,
      presets: [thumb: [width: 320], photo: [widths: [640, 1280]]]
    )

    on_exit(fn ->
      Application.delete_env(:storehouse, Purge)
      Application.delete_env(:storehouse, Storehouse.Variants)
    end)

    {:ok, file} =
      Storehouse.store(Path.join(@fixtures, "harbour.jpg"), adapter: Memory, owner: "accounts/7")

    %{original: file}
  end

  test "a file deleted: its URL, its variants', the app's, and its tag, once", %{original: file} do
    {:ok, _thumb} = Storehouse.variant(file, :thumb, adapter: Memory)
    assert :ok = Storehouse.delete(file.key, adapter: Memory)

    assert_received {:purged, request}
    refute_received {:purged, _another}

    variants =
      for {preset, width} <- [thumb: 320, photo: 640, photo: 1280],
          do: "https://cdn.example.com" <> Storehouse.variant_url(file, preset, width: width)

    assert Enum.sort(request.urls) ==
             Enum.sort([
               "https://cdn.example.com/memory/#{file.key}",
               "https://example.com/files/#{file.key}" | variants
             ])

    assert request.tags == [Purge.cache_tag(file.key)]
    assert request.prefixes == []
  end

  test "the files under a prefix deleted: the prefix's URLs", %{original: file} do
    assert {:ok, 1} = Storehouse.delete_prefix("accounts/7/", adapter: Memory)

    assert_received {:purged, request}
    refute_received {:purged, _another}

    assert request.prefixes == [
             "https://cdn.example.com/memory/accounts/7/",
             "https://cdn.example.com/variants/accounts/7/"
           ]

    assert request.urls == []
    assert file.key =~ "accounts/7/"
  end

  test "nothing without a purger", %{original: file} do
    Application.delete_env(:storehouse, Purge)
    assert :ok = Storehouse.delete(file.key, adapter: Memory)
    refute_received {:purged, _request}
  end

  test "a purge that fails is a job that fails, to be tried again", %{original: file} do
    Application.put_env(:storehouse, Purge,
      purger: {StorehouseTest.Purger, test: self(), result: {:error, :down}}
    )

    job = Storehouse.Jobs.Purge.job(Purge.request(file.key, adapter: Memory))

    assert {:error, :down} = Storehouse.Job.run(job)
    refute job.args |> inspect() |> String.contains?("test")
  end

  describe "Storehouse.Purge.Cloudflare" do
    setup do
      {:ok, server} =
        Bandit.start_link(
          plug: {Cloudflare, test: self()},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{endpoint: "http://127.0.0.1:#{port}/client/v4"}
    end

    test "URLs thirty a request, tags a hundred, with the zone's token", %{endpoint: endpoint} do
      urls = for n <- 1..45, do: "https://cdn.example.com/#{n}.jpg"
      tags = for n <- 1..120, do: "sh-#{n}"
      opts = [zone_id: "zone", api_token: "secret", endpoint: endpoint, by: [:urls, :tags]]

      assert :ok =
               Purge.Cloudflare.purge(%{urls: urls, tags: tags, prefixes: ["https://x/"]}, opts)

      assert_received {:cloudflare, "/client/v4/zones/zone/purge_cache", "Bearer secret",
                       %{"files" => first}}

      assert_received {:cloudflare, _path, _auth, %{"files" => second}}
      assert_received {:cloudflare, _path, _auth, %{"tags" => hundred}}
      assert_received {:cloudflare, _path, _auth, %{"tags" => twenty}}
      refute_received {:cloudflare, _path, _auth, _body}
      assert {length(first), length(second), length(hundred), length(twenty)} == {30, 15, 100, 20}
    end

    test "by URL alone by default, and the error of a request refused", %{endpoint: endpoint} do
      opts = [zone_id: "zone", api_token: "secret", endpoint: endpoint]

      assert {:error, {:cloudflare, 400, _body}} =
               Purge.Cloudflare.purge(
                 %{urls: ["https://fail/"], tags: ["sh-1"], prefixes: []},
                 opts
               )

      assert_received {:cloudflare, _path, _auth, %{"files" => ["https://fail/"]}}
      refute_received {:cloudflare, _path, _auth, %{"tags" => _tags}}
    end
  end
end
