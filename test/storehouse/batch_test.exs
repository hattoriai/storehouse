defmodule Storehouse.BatchTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Storehouse.{Batch, Memory}
  alias Storehouse.Plug.{Presign, Register}

  @harbour File.read!(Path.expand("../fixtures/harbour.jpg", __DIR__))
  @small File.read!(Path.expand("../fixtures/small.png", __DIR__))

  @secret String.duplicate("s", 64)

  setup do
    Memory.checkout()
  end

  defp presign(items, opts), do: Batch.presign(items, [secret: @secret] ++ opts)
  defp register(items, opts), do: Batch.register(items, [secret: @secret] ++ opts)

  defp item(name, body, type),
    do: %{"name" => name, "type" => type, "bytes" => byte_size(body)}

  defp sum(body), do: Base.encode64(:crypto.hash(:sha256, body))

  # The browser's part: each upload sent, as signed.
  defp send_all(results, bodies) do
    for {{:ok, upload}, body} <- Enum.zip(results, bodies) do
      200 = Memory.put_upload(upload, body)
      %{"key" => upload.key, "token" => upload.token}
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
               presign(items,
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
               presign(items, adapter: Memory, room: room)
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
               presign(items, adapter: Memory, existing: existing, room: byte_size(@small))
    end

    test "a batch larger than :max_items is refused" do
      items = for n <- 1..3, do: item("#{n}.png", @small, "image/png")
      assert presign(items, adapter: Memory, max_items: 2) == {:error, :too_many}
    end
  end

  describe "register/2" do
    test "checks each file in the store, and the same bytes twice in a batch are one" do
      bodies = [@harbour, @harbour, @small]
      items = for {b, n} <- Enum.with_index(bodies), do: item("#{n}.bin", b, nil)

      items =
        Enum.zip_with(items, ["image/jpeg", "image/jpeg", "image/png"], &%{&1 | "type" => &2})

      {:ok, signed} = presign(items, adapter: Memory, owner: 42)

      assert {:ok, [{:ok, first}, {:existing, again}, {:ok, small}]} =
               register(send_all(signed, bodies), adapter: Memory, owner: 42)

      assert again == first
      assert small.content_type == "image/png"
      assert Enum.sort(Memory.keys()) == Enum.sort([first.key, small.key])
    end

    test "another owner's upload is refused, and its file left as it is" do
      {:ok, [{:ok, upload}]} =
        presign([item("h.jpg", @harbour, "image/jpeg")], adapter: Memory, owner: 7)

      200 = Memory.put_upload(upload, @harbour)
      item = %{"key" => upload.key, "token" => upload.token}

      assert {:ok, [{:error, :invalid_token}]} = register([item], adapter: Memory, owner: 42)
      assert upload.key in Memory.keys()
    end

    test "a key it did not sign an upload to is refused, and the file there left as it is" do
      # A file already stored, of a type this endpoint does not take: were
      # its key checked as an upload, it would be deleted.
      {:ok, stored} =
        Storehouse.store(Path.expand("../fixtures/harbour.jpg", __DIR__), adapter: Memory)

      {:ok, [{:ok, mine}]} =
        presign([item("s.png", @small, "image/png")], adapter: Memory)

      for item <- [
            %{"key" => stored.key},
            %{"key" => stored.key, "token" => "forged"},
            %{"key" => stored.key, "token" => mine.token}
          ] do
        assert {:ok, [{:error, :invalid_token}]} =
                 register([item], adapter: Memory, accept: ["image/png"])
      end

      assert stored.key in Memory.keys()

      # Another secret's token is no token.
      {:ok, [{:ok, other}]} =
        Batch.presign([item("h.jpg", @harbour, "image/jpeg")],
          adapter: Memory,
          secret: String.duplicate("o", 64)
        )

      200 = Memory.put_upload(other, @harbour)

      assert {:ok, [{:error, :invalid_token}]} =
               register([%{"key" => other.key, "token" => other.token}], adapter: Memory)
    end

    test "a token is valid for a day" do
      {:ok, [{:ok, upload}]} = presign([item("h.jpg", @harbour, "image/jpeg")], adapter: Memory)
      200 = Memory.put_upload(upload, @harbour)
      item = %{"key" => upload.key, "token" => upload.token}

      assert {:ok, [{:error, :invalid_token}]} =
               register([item], adapter: Memory, token_max_age: -1)

      assert {:ok, [{:ok, _file}]} = register([item], adapter: Memory)
    end

    test "without a secret, nothing is signed" do
      assert_raise ArgumentError, ~r/:secret/, fn ->
        Batch.presign([item("s.png", @small, "image/png")], adapter: Memory)
      end

      assert_raise ArgumentError, ~r/:secret/, fn -> Batch.register([], adapter: Memory) end
    end

    test "the room is shared, by the sizes the store gives" do
      items = for n <- 1..2, do: item("h#{n}.jpg", @harbour, "image/jpeg")
      {:ok, signed} = presign(items, adapter: Memory)
      keys = send_all(signed, [@harbour, String.replace(@harbour, "a", "b")])

      assert {:ok, [{:ok, _file}, {:error, :storage_full}]} =
               register(keys, adapter: Memory, room: byte_size(@harbour) + 10)
    end
  end

  describe "the plugs" do
    defp post(plug, opts, body) do
      conn(:post, "/", body)
      |> Map.put(:secret_key_base, @secret)
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
            "uploads" => [
              %{"key" => upload["key"], "token" => upload["token"], "name" => "Quay.jpg"}
            ]
          })
        )

      assert %{"uploads" => [%{"file" => file}]} = json(conn)
      assert file["name"] == "Quay.jpg"
      assert file["width"] == 1200
    end

    test "register gives the app's own JSON of its records, with :then" do
      {:ok, [{:ok, upload}]} =
        presign([item("h.jpg", @harbour, "image/jpeg")], adapter: Memory)

      200 = Memory.put_upload(upload, @harbour)

      records = fn _conn, results ->
        for {:ok, file} <- results, do: %{"photo" => %{"id" => 1, "src" => file.url}}
      end

      conn =
        post(
          Register,
          [adapter: Memory, then: records],
          Storehouse.JSON.encode!(%{
            "uploads" => [%{"key" => upload.key, "token" => upload.token}]
          })
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

      # A form of another site, which the browser sends with the cookie and no
      # preflight: never read, whether a parser had it or not.
      for type <- ["text/plain", "application/x-www-form-urlencoded", nil] do
        body = ~s({"uploads":[{"key":"a/2026/10/x-a.png"}],"x":"="})
        conn = conn(:post, "/", body) |> Map.put(:secret_key_base, @secret)
        conn = if type, do: Plug.Conn.put_req_header(conn, "content-type", type), else: conn

        for plug <- [Presign, Register] do
          sent = plug.call(conn, plug.init(adapter: Memory))
          assert {sent.status, json(sent)} == {415, %{"error" => "unsupported_media_type"}}
        end
      end

      # An endpoint with no secret_key_base, and no :secret.
      assert_raise ArgumentError, fn ->
        conn(:post, "/", Storehouse.JSON.encode!(%{"uploads" => []}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Presign.call(Presign.init(adapter: Memory))
      end
    end

    test "a body Plug.Parsers has parsed already" do
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: Storehouse.JSON)

      conn =
        conn(
          :post,
          "/",
          Storehouse.JSON.encode!(%{"uploads" => [item("s.png", @small, "image/png")]})
        )
        |> Map.put(:secret_key_base, @secret)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parsers)
        |> Presign.call(Presign.init(adapter: Memory))

      assert %{"uploads" => [%{"upload" => _upload}]} = json(conn)
    end
  end
end
