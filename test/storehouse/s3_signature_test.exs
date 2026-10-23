defmodule Storehouse.S3.SignatureTest do
  # AWS's own examples of Signature Version 4 for S3:
  # https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  # https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  use ExUnit.Case, async: true

  alias Storehouse.S3.Signature

  @creds %{
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
  }
  @now ~U[2013-05-24 00:00:00Z]
  @uri URI.parse("https://examplebucket.s3.amazonaws.com/test.txt")

  test "a presigned URL" do
    signed = Signature.presign("GET", @uri, 86_400, @creds, now: @now)

    assert signed.query ==
             "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "a request signed in its Authorization header" do
    headers =
      Signature.sign_headers("GET", @uri, [{"Range", "bytes=0-9"}], @creds,
        now: @now,
        payload: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      )

    assert {"authorization",
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"} =
             List.keyfind(headers, "authorization", 0)
  end

  test "a PUT of an object, with its headers" do
    uri = URI.parse("https://examplebucket.s3.amazonaws.com/test$file.text")

    headers =
      Signature.sign_headers(
        "PUT",
        uri,
        [
          {"Date", "Fri, 24 May 2013 00:00:00 GMT"},
          {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
        ],
        @creds,
        now: @now,
        payload: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
      )

    {"authorization", authorization} = List.keyfind(headers, "authorization", 0)

    assert authorization =~
             "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
  end
end
