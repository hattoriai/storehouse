defmodule StorehouseTest.ClientApp do
  @moduledoc """
  An app for the JavaScript client's end-to-end test: its presign and
  register endpoints, and the local store's plug, which takes the uploads.
  """
  use Plug.Router

  plug(Storehouse.Local.Plug)
  plug(:match)
  plug(:dispatch)

  forward("/files/presign",
    to: Storehouse.Plug.Presign,
    init_opts: [owner: "accounts/42", accept: Storehouse.Check.images(), room: 100_000]
  )

  forward("/files/register",
    to: Storehouse.Plug.Register,
    init_opts: [owner: "accounts/42", accept: Storehouse.Check.images()]
  )

  # Large files in parts, straight to the bucket at S3_ENDPOINT.
  forward("/files/multipart",
    to: Storehouse.Plug.Multipart,
    init_opts: [owner: "accounts/42", adapter: Storehouse.S3, part_bytes: 5_242_880]
  )

  match _ do
    send_resp(conn, 404, "")
  end
end
