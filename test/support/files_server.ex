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

  # Answers of 5 MB that are not the file: a redirect, another 2xx, an
  # error, a chunk at a time.
  for {path, status} <- [{"/big-redirect", 302}, {"/big-203", 203}, {"/big-500", 500}] do
    get path do
      conn = conn |> put_resp_header("location", "/small.png") |> send_chunked(unquote(status))

      Enum.reduce_while(1..80, conn, fn _n, conn ->
        case chunk(conn, :binary.copy("x", 65_536)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    end
  end

  get "/slow" do
    conn = send_chunked(conn, 200)

    Enum.reduce_while(1..50, conn, fn _n, conn ->
      Process.sleep(100)

      case chunk(conn, "x") do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
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

defmodule StorehouseTest.PlainStore do
  @moduledoc "A store with the three callbacks only: no signed uploads or URLs."
  @behaviour Storehouse.Adapter

  @impl true
  def put(key, _path, _meta), do: {:ok, url(key)}
  @impl true
  def url(key), do: "/plain/" <> key
  @impl true
  def delete(_key), do: :ok
end
