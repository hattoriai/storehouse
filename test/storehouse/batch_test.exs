defmodule Storehouse.BatchTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Storehouse.{Batch, Memory}
  alias Storehouse.Plug.{Presign, Register}

  @harbour File.read!(Path.expand("../fixtures/harbour.jpg", __DIR__))
  @small File.read!(Path.expand("../fixtures/small.png", __DIR__))

  setup do
    Memory.checkout()
  end

  defp item(name, body, type),
    do: %{"name" => name, "type" => type, "bytes" => byte_size(body)}

  defp sum(body), do: Base.encode64(:crypto.hash(:sha256, body))

  # The browser's part: each upload sent, as signed.
  defp send_all(results, bodies) do
    for {{:ok, upload}, body} <- Enum.zip(results, bodies) do
      200 = Memory.put_upload(upload, body)
      %{"key" => upload.key}
    end
  end

  describe "presign/2" do
    test "one result per item, in order, some refused and the others signed" do
      items = [
        item("harbour.jpg", @harbour, "image/jpeg"),
        item("notes.txt", "hi", "text/plain"),
        item("big.png", String.duplicate("x", 200_000), "image/png"),
        %{"name" => "no size"}
      ]

      assert {:ok, [ok, not_accepted, too_large, invalid]} =
               Batch.presign(items,
                 adapter: Memory,
                 accept: Storehouse.Check.images(),
                 max_bytes: 100_000
               )

      assert {:ok, %{key: _key, method: "PUT"}} = ok
      assert not_accepted == {:error, :not_accepted}
      assert too_large == {:error, :too_large}
      assert invalid == {:error, :invalid_item}
    end

    test "the room is shared: each file takes from what the next one sees" do
      items = for n <- 1..3, do: item("h#{n}.jpg", @harbour, "image/jpeg")
      room = 2 * byte_size(@harbour)

      assert {:ok, [{:ok, _}, {:ok, _}, {:error, :storage_full}]} =
               Batch.presign(items, adapter: Memory, room: room)
    end

    test "a file the app has takes no room, and is not uploaded" do
      {:ok, kept} =
        Storehouse.store(Path.expand("../fixtures/harbour.jpg", __DIR__), adapter: Memory)

      existing = fn checksum -> if checksum == kept.checksum, do: kept end

      items = [
        Map.put(item("again.jpg", @harbour, "image/jpeg"), "checksum", sum(@harbour)),
        item("small.png", @small, "image/png")
      ]

      assert {:ok, [{:existing, ^kept}, {:ok, _upload}]} =
               Batch.presign(items, adapter: Memory, existing: existing, room: byte_size(@small))
    end

    test "a batch larger than :max_items is refused" do
      items = for n <- 1..3, do: item("#{n}.png", @small, "image/png")
      assert Batch.presign(items, adapter: Memory, max_items: 2) == {:error, :too_many}
    end
  end

  describe "register/2" do
    test "checks each file in the store, and the same bytes twice in a batch are one" do
      bodies = [@harbour, @harbour, @small]
      items = for {b, n} <- Enum.with_index(bodies), do: item("#{n}.bin", b, nil)

      items =
        Enum.zip_with(items, ["image/jpeg", "image/jpeg", "image/png"], &%{&1 | "type" => &2})

      {:ok, signed} = Batch.presign(items, adapter: Memory, owner: 42)

      assert {:ok, [{:ok, first}, {:existing, again}, {:ok, small}]} =
               Batch.register(send_all(signed, bodies), adapter: Memory, owner: 42)

      assert again == first
      assert small.content_type == "image/png"
      assert Enum.sort(Memory.keys()) == Enum.sort([first.key, small.key])
    end

    test "another owner's key is refused, and its file left as it is" do
      {:ok, [{:ok, upload}]} =
        Batch.presign([item("h.jpg", @harbour, "image/jpeg")], adapter: Memory, owner: 7)

      200 = Memory.put_upload(upload, @harbour)

      assert {:ok, [{:error, :not_owner}]} =
               Batch.register([%{"key" => upload.key}], adapter: Memory, owner: 42)

      assert upload.key in Memory.keys()
    end

    test "the room is shared, by the sizes the store gives" do
      items = for n <- 1..2, do: item("h#{n}.jpg", @harbour, "image/jpeg")
      {:ok, signed} = Batch.presign(items, adapter: Memory)
      keys = send_all(signed, [@harbour, String.replace(@harbour, "a", "b")])

      assert {:ok, [{:ok, _file}, {:error, :storage_full}]} =
               Batch.register(keys, adapter: Memory, room: byte_size(@harbour) + 10)
    end
  end

  describe "the plugs" do
    defp post(plug, opts, body) do
      conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> plug.call(plug.init(opts))
    end

    defp json(conn), do: Storehouse.JSON.decode!(conn.resp_body)

    test "presign and register a batch in JSON" do
      owner = fn _conn -> "accounts/42" end

      body =
        Storehouse.JSON.encode!(%{
          "uploads" => [
            item("harbour.jpg", @harbour, "image/jpeg"),
            item("page.html", "<p>", "text/html")
          ]
        })

      conn =
        post(
          Presign,
          [adapter: Memory, owner: owner, accept: ["image/jpeg"]],
          body
        )

      assert conn.status == 200
      assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

      assert %{"uploads" => [%{"upload" => upload}, %{"error" => "not_accepted"}]} = json(conn)
      assert "accounts/42/" <> _ = upload["key"]

      200 = Memory.put_upload(%{url: upload["url"]}, @harbour)

      conn =
        post(
          Register,
          [adapter: Memory, owner: owner],
          Storehouse.JSON.encode!(%{
            "uploads" => [%{"key" => upload["key"], "name" => "Quay.jpg"}]
          })
        )

      assert %{"uploads" => [%{"file" => file}]} = json(conn)
      assert file["name"] == "Quay.jpg"
      assert file["width"] == 1200
    end

    test "register gives the app's own JSON of its records, with :then" do
      {:ok, [{:ok, upload}]} =
        Batch.presign([item("h.jpg", @harbour, "image/jpeg")], adapter: Memory)

      200 = Memory.put_upload(upload, @harbour)

      records = fn _conn, results ->
        for {:ok, file} <- results, do: %{"photo" => %{"id" => 1, "src" => file.url}}
      end

      conn =
        post(
          Register,
          [adapter: Memory, then: records],
          Storehouse.JSON.encode!(%{"uploads" => [%{"key" => upload.key}]})
        )

      assert json(conn) == %{
               "uploads" => [%{"photo" => %{"id" => 1, "src" => "/memory/" <> upload.key}}]
             }
    end

    test "a body that is not a batch, a batch too large, and a GET" do
      assert post(Presign, [adapter: Memory], "{not json").status == 400
      assert post(Presign, [adapter: Memory], ~s({"files": []})).status == 400

      too_many = Storehouse.JSON.encode!(%{"uploads" => [%{}, %{}]})
      conn = post(Register, [adapter: Memory, max_items: 1], too_many)
      assert conn.status == 413
      assert json(conn) == %{"error" => "too_many"}

      conn = conn(:get, "/") |> Presign.call(Presign.init([]))
      assert conn.status == 405
    end

    test "a body Plug.Parsers has parsed already" do
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: Storehouse.JSON)

      conn =
        conn(
          :post,
          "/",
          Storehouse.JSON.encode!(%{"uploads" => [item("s.png", @small, "image/png")]})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parsers)
        |> Presign.call(Presign.init(adapter: Memory))

      assert %{"uploads" => [%{"upload" => _upload}]} = json(conn)
    end
  end
end
