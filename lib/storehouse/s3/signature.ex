defmodule Storehouse.S3.Signature do
  @moduledoc false
  # AWS Signature Version 4, for S3 and the stores that speak its API
  # (Cloudflare R2, MinIO, Tigris, Backblaze B2, Google Cloud Storage's
  # interoperability): requests signed in an `Authorization` header, and
  # URLs signed in their query (presigned), which a browser uses without
  # the keys.
  #
  # https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html

  @algorithm "AWS4-HMAC-SHA256"
  @unsigned "UNSIGNED-PAYLOAD"

  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          required(:region) => String.t(),
          optional(:session_token) => String.t() | nil
        }

  @doc """
  The headers of a request signed with an `Authorization` header: the
  given ones, `host`, `x-amz-date`, `x-amz-content-sha256` and
  `authorization`. `payload` is the body's SHA-256 in hex, or
  `"UNSIGNED-PAYLOAD"`.
  """
  def sign_headers(method, %URI{} = uri, headers, creds, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    payload = Keyword.get(opts, :payload, @unsigned)
    service = Keyword.get(opts, :service, "s3")
    {date, amz_date} = dates(now)

    headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Kernel.++([
        {"host", host(uri)},
        {"x-amz-date", amz_date},
        {"x-amz-content-sha256", payload}
      ])
      |> then(
        &if creds[:session_token],
          do: [{"x-amz-security-token", creds.session_token} | &1],
          else: &1
      )

    {canonical_headers, signed} = canonical_headers(headers)
    query = canonical_query(URI.decode_query(uri.query || ""))

    request =
      Enum.join(
        [method, canonical_path(uri.path), query, canonical_headers, signed, payload],
        "\n"
      )

    scope = scope(date, creds.region, service)
    signature = signature(request, amz_date, scope, date, creds, service)

    authorization =
      "#{@algorithm} Credential=#{creds.access_key_id}/#{scope}, SignedHeaders=#{signed}, Signature=#{signature}"

    headers ++ [{"authorization", authorization}]
  end

  @doc """
  A URL signed in its query, for `method`, valid `expires` seconds from
  now: the `headers` given are signed too, and the request must send
  them as they are (a `content-type`, a `content-length`).
  """
  def presign(method, %URI{} = uri, expires, creds, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    service = Keyword.get(opts, :service, "s3")
    headers = Enum.map(Keyword.get(opts, :headers, []), fn {k, v} -> {String.downcase(k), v} end)
    {date, amz_date} = dates(now)
    scope = scope(date, creds.region, service)
    {canonical_headers, signed} = canonical_headers([{"host", host(uri)} | headers])

    params =
      URI.decode_query(uri.query || "")
      |> Map.merge(%{
        "X-Amz-Algorithm" => @algorithm,
        "X-Amz-Credential" => "#{creds.access_key_id}/#{scope}",
        "X-Amz-Date" => amz_date,
        "X-Amz-Expires" => Integer.to_string(expires),
        "X-Amz-SignedHeaders" => signed
      })
      |> then(
        &if creds[:session_token],
          do: Map.put(&1, "X-Amz-Security-Token", creds.session_token),
          else: &1
      )

    query = canonical_query(params)

    request =
      Enum.join(
        [method, canonical_path(uri.path), query, canonical_headers, signed, @unsigned],
        "\n"
      )

    signature = signature(request, amz_date, scope, date, creds, service)
    %{uri | query: query <> "&X-Amz-Signature=" <> signature}
  end

  defp signature(request, amz_date, scope, date, creds, service) do
    to_sign = Enum.join([@algorithm, amz_date, scope, hex(sha256(request))], "\n")

    ("AWS4" <> creds.secret_access_key)
    |> hmac(date)
    |> hmac(creds.region)
    |> hmac(service)
    |> hmac("aws4_request")
    |> hmac(to_sign)
    |> hex()
  end

  defp dates(now) do
    now = DateTime.truncate(now, :second)
    date = Calendar.strftime(now, "%Y%m%d")
    {date, date <> Calendar.strftime(now, "T%H%M%SZ")}
  end

  defp scope(date, region, service), do: "#{date}/#{region}/#{service}/aws4_request"

  defp canonical_headers(headers) do
    headers =
      headers
      |> Enum.map(fn {k, v} ->
        {String.downcase(k), v |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    {Enum.map_join(headers, "", fn {k, v} -> "#{k}:#{v}\n" end),
     Enum.map_join(headers, ";", &elem(&1, 0))}
  end

  defp canonical_query(params) do
    params
    |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # Each segment encoded, the slashes kept (S3 encodes a key once).
  defp canonical_path(nil), do: "/"
  defp canonical_path(""), do: "/"

  defp canonical_path(path),
    do: path |> String.split("/") |> Enum.map_join("/", &encode(URI.decode(&1)))

  @doc false
  def encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp host(%URI{host: host, port: port, scheme: scheme}) do
    if (scheme == "https" and port in [nil, 443]) or (scheme == "http" and port in [nil, 80]),
      do: host,
      else: "#{host}:#{port}"
  end

  @doc false
  def sha256(data), do: :crypto.hash(:sha256, data)
  @doc false
  def hex(binary), do: Base.encode16(binary, case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
