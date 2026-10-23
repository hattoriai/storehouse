defmodule Storehouse.LiveTest do
  # The files of a LiveView upload, stored with Storehouse.Live.consume/3.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Storehouse.Local.Plug, as: FilePlug

  @endpoint StorehouseTest.Endpoint
  @fixtures Path.expand("../fixtures", __DIR__)

  setup_all do
    start_supervised!({Phoenix.PubSub, name: StorehouseTest.PubSub})
    start_supervised!(StorehouseTest.Endpoint)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storehouse-live-#{System.unique_integer([:positive])}")

    Application.put_env(:storehouse, Storehouse.Local,
      root: root,
      secret: String.duplicate("storehouse-live-", 3)
    )

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp upload(view, files) do
    input =
      file_input(
        view,
        "#upload",
        :photos,
        for name <- files do
          %{
            name: name,
            content: File.read!(Path.join(@fixtures, name)),
            type: MIME.from_path(name)
          }
        end
      )

    for name <- files, do: render_upload(input, name)
    input
  end

  test "stores each file once, when it is done", %{root: root} do
    {:ok, view, _html} = live(build_conn(), "/")
    upload(view, ["harbour.jpg", "small.png"])

    results = view |> element("#results") |> render()

    assert results =~
             ~r"harbour.jpg: image/jpeg 1200x800 /uploads/\d{4}/\d{2}/[0-9a-f-]+-harbour\.jpg"

    assert results =~ "small.png: image/png 4x3"
    # Once each: the change of the form after them stores nothing again.
    view |> element("#upload") |> render_change(%{})
    assert length(Regex.scan(~r/<li>/, render(view))) == 2
    assert length(Path.wildcard(Path.join(root, "**/*.{jpg,png}"))) == 2
  end

  test "says what was refused: by its bytes, and by the upload's own limits" do
    {:ok, view, _html} = live(build_conn(), "/")
    upload(view, ["not-an-image.png"])
    assert render(view) =~ "not-an-image.png: :not_accepted"

    input =
      file_input(view, "#upload", :photos, [
        %{name: "a.gif", content: "GIF89a", type: "image/gif"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "a.gif")
  end

  describe "an upload straight to the store" do
    # The browser's part: the file, to the URL the server signed for it.
    defp upload_direct(view, name, content, type) do
      input = file_input(view, "#upload", :photos, [%{name: name, content: content, type: type}])
      [%{"ref" => ref}] = input.entries
      render_upload(input, name, 50)

      %{socket: socket} = :sys.get_state(view.pid)
      upload = socket.assigns.uploads.photos.entry_refs_to_metas[ref]

      conn =
        Plug.Test.conn(:put, upload.url, content)
        |> Plug.Conn.put_req_header("content-type", upload.headers["content-type"])
        |> FilePlug.call(FilePlug.init([]))

      assert conn.status == 200
      render_upload(input, name, 50)
      upload
    end

    test "is signed, sent to the store, and checked there", %{root: root} do
      {:ok, view, _html} = live(build_conn(), "/direct")
      data = File.read!(Path.join(@fixtures, "harbour.jpg"))
      upload = upload_direct(view, "harbour.jpg", data, "image/jpeg")

      assert %{uploader: "Storehouse", method: "PUT"} = upload
      assert render(view) =~ "harbour.jpg: image/jpeg 1200x800 #{upload.key}"
      assert File.read!(Path.join(root, upload.key)) == data
    end

    test "is deleted from the store when its bytes are not what it said", %{root: root} do
      {:ok, view, _html} = live(build_conn(), "/direct")

      upload =
        upload_direct(
          view,
          "page.png",
          String.pad_trailing("<script>alert(1)</script>", 100),
          "image/png"
        )

      assert render(view) =~ "page.png: :not_accepted"
      refute File.exists?(Path.join(root, upload.key))
    end

    test "goes through the LiveView with a store that does not sign uploads" do
      Application.put_env(:storehouse, :adapter, StorehouseTest.PlainStore)
      on_exit(fn -> Application.delete_env(:storehouse, :adapter) end)

      {:ok, view, _html} = live(build_conn(), "/direct")
      upload(view, ["small.png"])
      assert render(view) =~ ~r"small.png: image/png 4x3 \d{4}/"
    end
  end
end
