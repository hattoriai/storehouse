defmodule Storehouse.ApplicationTest do
  use ExUnit.Case, async: true

  # A release starts what an app's applications list: :httpd_util, which
  # reads HTTP dates (Storehouse.Proxy, Storehouse.S3), is :inets's.
  test "Storehouse's applications include :inets, for the HTTP dates it reads" do
    assert :inets in Application.spec(:storehouse, :applications)

    assert {{2026, 10, 26}, {10, 0, 0}} =
             :httpd_util.convert_request_date(~c"Mon, 26 Oct 2026 10:00:00 GMT")
  end
end
