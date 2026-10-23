defmodule Storehouse.Redirect do
  @moduledoc """
  A lasting URL of your app for a file that is not public: it checks that
  the person may see the file, then redirects to a URL the store signs
  for a few minutes (`Storehouse.signed_url/2`). Keep this URL in your
  records and documents, not the signed one, which expires.

  In the router, in a scope that has the person (`:fetch_session`, your
  authentication):

      forward "/files", Storehouse.Redirect, authorize: &MyAppWeb.Files.allowed?/2

  `/files/2026/10/0b6…-board.png` then redirects to the file. The
  function takes the conn and the key; a key it refuses, or that is not a
  valid key, gives `404`, so that no one learns which files exist.

      defmodule MyAppWeb.Files do
        def allowed?(conn, key), do: MyApp.Files.visible?(conn.assigns.current_scope, key)
      end

  ## Options

    * `:authorize` - the function (required). `true` lets everyone in: for
      a store whose files are private only so that their URLs expire.
    * `:expires_in` - how long the signed URL is valid, in seconds. The
      default is 300.
    * `:disposition` - `"inline"` or `"attachment"`, for the signed URL.
      A request's `?download=1` asks for a download.
    * `:adapter` - the store. The default is `Storehouse.adapter/0`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    opts = Keyword.validate!(opts, [:authorize, :adapter, :disposition, expires_in: 300])

    case opts[:authorize] do
      fun when is_function(fun, 2) or fun == true ->
        opts

      _other ->
        raise ArgumentError,
              "Storehouse.Redirect needs authorize: a function of the conn and the key, or true"
    end
  end

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    key = Enum.join(conn.path_info, "/")
    conn = fetch_query_params(conn)

    with true <- Storehouse.valid_key?(key),
         true <- allowed?(opts[:authorize], conn, key),
         {:ok, url} <- Storehouse.signed_url(key, signed_opts(conn, key, opts)) do
      conn
      |> put_resp_header("location", url)
      |> put_resp_header("cache-control", "private, max-age=#{max(opts[:expires_in] - 60, 0)}")
      |> send_resp(302, "")
      |> halt()
    else
      _refused -> conn |> send_resp(404, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn |> send_resp(405, "") |> halt()

  defp allowed?(true, _conn, _key), do: true
  defp allowed?(fun, conn, key), do: fun.(conn, key) == true

  defp signed_opts(conn, key, opts) do
    base = Keyword.take(opts, [:adapter, :expires_in, :disposition])

    if conn.query_params["download"] in ["1", "true"],
      do: Keyword.merge(base, disposition: "attachment", filename: Path.basename(key)),
      else: base
  end
end
