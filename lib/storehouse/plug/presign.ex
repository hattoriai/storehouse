defmodule Storehouse.Plug.Presign do
  @moduledoc """
  Signs uploads straight to the store for a frontend that is not a
  LiveView: a JSON endpoint in front of `Storehouse.Batch.presign/2`.

      # lib/my_app_web/router.ex, behind your authentication
      scope "/files" do
        pipe_through [:api, :require_user]

        forward "/presign", Storehouse.Plug.Presign,
          owner: &MyAppWeb.Files.owner/1,
          room: &MyAppWeb.Files.room/1,
          existing: &MyAppWeb.Files.existing/2,
          accept: Storehouse.Check.images(),
          max_bytes: 50_000_000

        forward "/register", Storehouse.Plug.Register, ...
      end

  A `POST` of

      {"uploads": [{"name": "harbour.jpg", "type": "image/jpeg", "bytes": 35367, "checksum": "e3b0…"}]}

  is answered `200` with one result per upload, in order:

      {"uploads": [
        {"upload": {"key": "accounts/42/2026/10/…-harbour.jpg", "method": "PUT", "url": "https://…", "headers": {"content-type": "image/jpeg", …}}},
        {"existing": {"key": …, "url": …, …}},
        {"error": "storage_full"}
      ]}

  The browser sends each file to its `url` with its `method` and exactly
  its `headers`, then gives the keys to `Storehouse.Plug.Register`. A body
  that is not that JSON gives `400`, and a batch larger than `:max_items`
  `413`, with `{"error": code}`.

  ## Options

    * `:owner` - a function of the conn that gives the owner whose files
      these are (`Storehouse.store/2`'s `:owner`), or `nil`.
    * `:room` - a function of the conn that gives the bytes the owner may
      still store, shared by the batch, or `:infinity`.
    * `:existing` - a function of the conn and a checksum that gives the
      file the app has already with it, or `nil` (`:existing` of
      `Storehouse.presign_upload/4`).
    * the other options of `Storehouse.Batch.presign/2` (`:accept`,
      `:max_bytes`, `:key`, `:cache`, `:expires_in`, `:adapter`,
      `:max_items`), as they are.
  """

  @behaviour Plug

  alias Storehouse.Plug.Batch

  @impl Plug
  def init(opts), do: Batch.init(opts, [])

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    with {:ok, conn, items} <- Batch.items(conn),
         {:ok, results} <- Storehouse.Batch.presign(items, Batch.batch_opts(conn, opts)) do
      Batch.json(conn, 200, %{"uploads" => Enum.map(results, &Batch.result/1)})
    else
      {:error, :too_many} -> Batch.error(conn, 413, :too_many)
      {:error, conn} -> Batch.error(conn, 400, :invalid_request)
    end
  end

  def call(conn, _opts), do: Batch.error(conn, 405, :method_not_allowed)
end
