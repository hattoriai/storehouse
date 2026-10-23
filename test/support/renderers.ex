defmodule StorehouseTest.Renderers do
  @moduledoc false

  defmodule Counting do
    @moduledoc false
    # Libvips's, telling the test each time it renders, slowly.
    @behaviour Storehouse.Renderer

    alias Storehouse.Renderer.Vix

    @impl true
    def render(source, destination, variant, opts) do
      send(Keyword.fetch!(opts, :test), {:rendered, node(), variant.preset, variant.width})
      Process.sleep(Keyword.get(opts, :sleep, 0))
      Vix.render(source, destination, variant, [])
    end
  end

  defmodule Urls do
    @moduledoc false
    # A service's URLs, rendering nothing.
    @behaviour Storehouse.Renderer

    @impl true
    def url(variant, file, _opts),
      do: "https://images.example.com/#{variant.preset}/#{variant.width}/#{file.key}"
  end
end
