defmodule StorehouseTest.UploadLive do
  @moduledoc "A LiveView with an upload whose files Storehouse.Live stores."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(results: [])
     |> allow_upload(:photos,
       accept: ~w(.png .jpg .jpeg .txt),
       max_file_size: 100_000,
       max_entries: 3,
       auto_upload: true,
       progress: &progress/3
     )}
  end

  defp progress(:photos, _entry, socket), do: {:noreply, consume(socket)}

  defp consume(socket) do
    {socket, results} =
      Storehouse.Live.consume(socket, :photos, accept: Storehouse.Check.images())

    assign(socket, :results, socket.assigns.results ++ Enum.map(results, &describe/1))
  end

  defp describe({entry, {:ok, file}}),
    do: "#{entry.client_name}: #{file.content_type} #{file.width}x#{file.height} #{file.url}"

  defp describe({entry, {:error, reason}}), do: "#{entry.client_name}: #{inspect(reason)}"

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, consume(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload" phx-change="validate">
      <.live_file_input upload={@uploads.photos} />
    </form>
    <ul id="results"><li :for={result <- @results}>{result}</li></ul>
    """
  end
end

defmodule StorehouseTest.DirectLive do
  @moduledoc "A LiveView whose files go straight to the store (Storehouse.Live.allow/3)."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(results: [])
     |> Storehouse.Live.allow(:photos,
       accept: ~w(.png .jpg .jpeg),
       max_file_size: 100_000,
       max_entries: 3,
       auto_upload: true,
       progress: &progress/3
     )}
  end

  defp progress(:photos, _entry, socket) do
    {socket, results} =
      Storehouse.Live.consume(socket, :photos, accept: Storehouse.Check.images())

    {:noreply, assign(socket, :results, socket.assigns.results ++ Enum.map(results, &describe/1))}
  end

  defp describe({entry, {:ok, file}}),
    do: "#{entry.client_name}: #{file.content_type} #{file.width}x#{file.height} #{file.key}"

  defp describe({entry, {:error, reason}}), do: "#{entry.client_name}: #{inspect(reason)}"

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload" phx-change="validate">
      <.live_file_input upload={@uploads.photos} />
    </form>
    <ul id="results"><li :for={result <- @results}>{result}</li></ul>
    """
  end
end

defmodule StorehouseTest.StreamLive do
  @moduledoc "A LiveView whose files stream through it to the store (mode: :stream)."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(results: [])
     |> Storehouse.Live.allow(:photos,
       mode: :stream,
       types: Storehouse.Check.images() ++ ["application/octet-stream"],
       accept: :any,
       max_file_size: 20_000_000,
       max_entries: 3,
       chunk_size: 256_000,
       auto_upload: true,
       progress: &progress/3
     )}
  end

  defp progress(:photos, _entry, socket) do
    {socket, results} = Storehouse.Live.consume(socket, :photos)
    {:noreply, assign(socket, :results, socket.assigns.results ++ Enum.map(results, &describe/1))}
  end

  defp describe({entry, {:ok, file}}),
    do:
      "#{entry.client_name}: #{file.content_type} #{file.bytes} #{file.width}x#{file.height} #{file.key} #{file.checksum}"

  defp describe({entry, {:error, reason}}), do: "#{entry.client_name}: #{inspect(reason)}"

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload" phx-change="validate">
      <.live_file_input upload={@uploads.photos} />
    </form>
    <ul id="results"><li :for={result <- @results}>{result}</li></ul>
    """
  end
end

defmodule StorehouseTest.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)
    live("/", StorehouseTest.UploadLive)
    live("/direct", StorehouseTest.DirectLive)
    live("/stream", StorehouseTest.StreamLive)
  end
end

defmodule StorehouseTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :storehouse

  @session [store: :cookie, key: "_storehouse_test", signing_salt: "storehouse-test"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
  plug(Plug.Session, @session)
  plug(StorehouseTest.Router)
end
