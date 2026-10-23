defmodule StorehouseTest.FilesServer do
  @moduledoc "An HTTP server of files, for the tests of Storehouse.fetch/2."
  use Plug.Router

  @fixtures Path.expand("../fixtures", __DIR__)

  plug(:match)
  plug(:dispatch)

  get "/small.png" do
    conn
    |> put_resp_content_type("image/png")
    |> send_file(200, Path.join(@fixtures, "small.png"))
  end

  get "/harbour.jpg" do
    conn
    |> put_resp_content_type("image/jpeg")
    |> send_file(200, Path.join(@fixtures, "harbour.jpg"))
  end

  get "/page.png" do
    conn |> put_resp_content_type("text/html") |> send_resp(200, "<script>alert(1)</script>")
  end

  get "/moved" do
    conn |> put_resp_header("location", "/small.png") |> send_resp(302, "")
  end

  get "/away" do
    conn |> put_resp_header("location", "http://169.254.169.254/latest") |> send_resp(302, "")
  end

  get "/loop" do
    conn |> put_resp_header("location", "/loop") |> send_resp(302, "")
  end

  match _ do
    send_resp(conn, 404, "")
  end

  @doc "Starts the server on a free port, and gives the port."
  def start do
    {:ok, pid} =
      Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
