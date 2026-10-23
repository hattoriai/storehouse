defmodule Storehouse.StreamTest do
  # Uploads streamed through the LiveView to the store as each chunk comes
  # (mode: :stream), with no file on the app's disk: to the local disk, and
  # to S3 in the parts of a multipart upload.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint StorehouseTest.Endpoint
  @fixtures Path.expand("../fixtures", __DIR__)

  setup_all do
    start_supervised!({Phoenix.PubSub, name: StorehouseTest.PubSub})
    start_supervised!(StorehouseTest.Endpoint)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-stream-#{System.unique_integer([:positive])}")
    Application.put_env(:storehouse, Storehouse.Local, root: root)

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      Application.delete_env(:storehouse, :adapter)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp upload(name, content, type) do
    {:ok, view, _html} = live(build_conn(), "/stream")
    input = file_input(view, "#upload", :photos, [%{name: name, content: content, type: type}])
    result = render_upload(input, name)
    {view, result}
  end

  defp sha(data), do: Base.encode64(:crypto.hash(:sha256, data))

  test "a file streams to the store, checked, with its checksum, and nothing on the disk but it",
       %{root: root} do
    data = File.read!(Path.join(@fixtures, "harbour.jpg"))
    {view, _result} = upload("harbour.jpg", data, "image/jpeg")

    html = render(view)

    [key] =
      Regex.run(~r{harbour.jpg: image/jpeg 35367 1200x800 (\S+) }, html, capture: :all_but_first)

    assert html =~ sha(data)
    assert File.read!(Path.join(root, key)) == data
    # No part file left beside it.
    assert root |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) == [
             Path.join(root, key)
           ]
  end

  test "a file whose bytes are not what it said is stopped, and nothing of it stays", %{
    root: root
  } do
    page = String.pad_trailing("<html><script>alert(1)</script></html>", 300_000)
    {_view, result} = upload("page.png", page, "image/png")

    # The entry has an error, and no result.
    assert result =~ ~r/data-phx-error-refs="\d+"/
    assert root |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) == []
  end

  @tag :s3
  test "a large file streams to S3 in the parts of a multipart upload" do
    endpoint = System.fetch_env!("S3_ENDPOINT")
    bucket = "stream-#{System.unique_integer([:positive])}"
    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, {{_v, 200, _r}, _h, _b}} =
      :httpc.request(
        :put,
        {String.to_charlist("#{endpoint}/#{bucket}"), [], ~c"text/plain", ""},
        [],
        []
      )

    Application.put_env(:storehouse, :adapter, Storehouse.S3)

    Application.put_env(:storehouse, Storehouse.S3,
      bucket: bucket,
      region: "us-east-1",
      endpoint: endpoint,
      access_key_id: "test",
      secret_access_key: "test",
      part_size: 5_242_880
    )

    on_exit(fn -> Application.delete_env(:storehouse, Storehouse.S3) end)

    data = :crypto.strong_rand_bytes(12_000_000)
    {view, _result} = upload("archive.bin", data, "application/octet-stream")

    [key] =
      Regex.run(~r{archive.bin: application/octet-stream 12000000 x (\S+) }, render(view),
        capture: :all_but_first
      )

    assert render(view) =~ sha(data)

    {:ok, url} = Storehouse.signed_url(key)

    {:ok, {{_v, 200, _r}, _h, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    assert body == data
  end
end
