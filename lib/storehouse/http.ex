defmodule Storehouse.HTTP do
  @moduledoc false
  # Storehouse's requests (to S3, a CDN's API, the app's own URLs), with
  # Req: the bytes as they come, no redirect followed, nothing tried again
  # on its own (a caller that can, does), no body decoded.

  @doc false
  @spec request(atom(), String.t(), [{String.t(), String.t()}], term(), keyword()) ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    method
    |> base(url, headers, opts)
    |> Keyword.merge(body(body))
    |> Req.request()
    |> answer()
  end

  @doc false
  # The options of every request: those of the caller's after them.
  def base(method, url, headers, opts) do
    [
      method: method,
      url: url,
      headers: headers,
      raw: true,
      compressed: false,
      redirect: false,
      retry: false,
      receive_timeout: Keyword.get(opts, :timeout, 60_000),
      connect_options: [timeout: Keyword.get(opts, :connect_timeout, 10_000)]
    ] ++ Keyword.drop(opts, [:timeout, :connect_timeout])
  end

  defp body(nil), do: []
  defp body(body) when is_binary(body), do: [body: body]
  # A file streamed from the disk, a megabyte at a time.
  defp body({:file, path}), do: [body: File.stream!(path, 1_048_576)]

  @doc false
  def answer({:ok, %Req.Response{status: status, headers: headers, body: body}}),
    do: {:ok, status, headers(headers), body}

  def answer({:error, %{reason: reason}}), do: {:error, reason}
  def answer({:error, error}), do: {:error, error}

  # Each header once, by its name in lower case; values joined as HTTP
  # joins them.
  defp headers(headers) when is_map(headers),
    do: for({name, values} <- headers, do: {String.downcase(name), Enum.join(values, ", ")})

  defp headers(headers), do: for({name, value} <- headers, do: {String.downcase(name), value})
end
