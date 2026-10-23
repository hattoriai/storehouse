if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Storehouse.Components do
    @moduledoc """
    Function components for HEEx, from `Storehouse.Responsive`'s data.

        import Storehouse.Components

        <.img file={@photo.image} preset={:photo} sizes="(min-width: 60rem) 60rem, 100vw" alt={@photo.caption} />
    """

    use Phoenix.Component

    alias Storehouse.Responsive

    @safe_placeholder ~r/\Adata:image\/(webp|png|jpeg);base64,[A-Za-z0-9+\/=]+\z/
    @safe_color ~r/\A#[0-9a-f]{6}\z/

    @doc """
    An `<img>` of `file` with `preset`'s sizes (`Storehouse.Responsive.resolve/3`):
    its `src`, `srcset`, `sizes`, `width` and `height`, and its placeholder
    and colour painted under it while it loads, when its analysis has them.
    """
    attr(:file, Storehouse.File, required: true)
    attr(:preset, :atom, required: true)
    attr(:sizes, :string, default: nil, doc: "the layout's slot for it, at each screen's width")
    attr(:src, :integer, default: nil, doc: "the width of `src`, for a browser without `srcset`")

    attr(:placeholder, :boolean,
      default: true,
      doc: "paint the placeholder and colour under it while it loads"
    )

    attr(:options, :list, default: [], doc: "`Storehouse.Variants.url/3`'s")

    attr(:rest, :global,
      include: ~w(alt loading decoding fetchpriority crossorigin referrerpolicy)
    )

    def img(assigns) do
      options = if assigns.src, do: [src: assigns.src], else: []
      image = Responsive.resolve(assigns.file, assigns.preset, options ++ assigns.options)

      assigns =
        assigns
        |> assign(:image, image)
        |> assign(:painted, painted(assigns.placeholder && style(image)))

      ~H"""
      <img
        src={@image.src}
        srcset={@image.srcset}
        sizes={@sizes}
        width={@image.width}
        height={@image.height}
        {@painted}
        {@rest}
      />
      """
    end

    defp painted(nil), do: []
    defp painted(false), do: []
    defp painted(style), do: [style: style]

    # Only a data URI of an image and a colour, as the steps make them, go
    # into the style.
    defp style(%{placeholder: placeholder, color: color}) do
      color = if is_binary(color) and color =~ @safe_color, do: color

      cond do
        is_binary(placeholder) and placeholder =~ @safe_placeholder ->
          "background: #{color || "transparent"} url(#{placeholder}) center / cover no-repeat"

        color ->
          "background-color: #{color}"

        true ->
          nil
      end
    end
  end
end
