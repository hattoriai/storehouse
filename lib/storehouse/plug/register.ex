defmodule Storehouse.Plug.Register do
  @moduledoc """
  Checks the files a browser uploaded straight to the store, signed by
  `Storehouse.Plug.Presign`, and gives them to the app: a JSON endpoint in
  front of `Storehouse.Batch.register/2`.

      forward "/register", Storehouse.Plug.Register,
        owner: &MyAppWeb.Files.owner/1,
        room: &MyAppWeb.Files.room/1,
        existing: &MyAppWeb.Files.existing/2,
        accept: Storehouse.Check.images(),
        then: &MyAppWeb.Files.registered/2

  A `POST` of

      {"uploads": [{"key": "accounts/42/2026/10/…-harbour.jpg", "name": "harbour.jpg"}]}

  checks each file in the store by its bytes, then calls `:then` with the
  conn and the results (`{:ok, file}`, `{:existing, file}` or
  `{:error, code}`, one per upload, in order). It gives what the app
  makes of them (its records, in one transaction), as a list of JSON
  values, one per upload, which is answered `200` as
  `{"uploads": [...]}`. Without `:then`, each result is its file:

      {"uploads": [{"file": {...}}, {"existing": {...}}, {"error": "not_owner"}]}

  A key of another owner's file (`:owner`) is refused, and that file left
  as it is, so a browser cannot claim another's file by its key.

  ## Options

    * `:owner`, `:room`, `:existing` - functions of the conn, as for
      `Storehouse.Plug.Presign`.
    * `:then` - a function of the conn and the results that gives the
      JSON value of each.
    * the other options of `Storehouse.Batch.register/2` (`:accept`,
      `:max_bytes`, `:max_pixels`, `:metadata`, `:adapter`, `:max_items`),
      as they are.
  """

  @behaviour Plug

  alias Storehouse.Plug.Batch

  @impl Plug
  def init(opts), do: Batch.init(opts, [:then])

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    with {:ok, conn, items} <- Batch.items(conn),
         {:ok, results} <- Storehouse.Batch.register(items, Batch.batch_opts(conn, opts)) do
      values =
        case opts[:then] do
          nil -> Enum.map(results, &Batch.result/1)
          fun -> fun.(conn, results)
        end

      Batch.json(conn, 200, %{"uploads" => values})
    else
      {:error, :too_many} -> Batch.error(conn, 413, :too_many)
      {:error, conn} -> Batch.error(conn, 400, :invalid_request)
    end
  end

  def call(conn, _opts), do: Batch.error(conn, 405, :method_not_allowed)
end
