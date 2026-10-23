defmodule Storehouse.SweeperMultipartTest do
  use ExUnit.Case, async: true

  # A store with two uploads open, one of an hour ago and one of two days
  # ago, that tells the test which it gives up.
  defmodule Open do
    @moduledoc false
    def put(_key, _path, _meta), do: {:ok, ""}
    def url(key), do: key
    def delete(_key), do: :ok
    def list(_prefix), do: {:ok, []}

    def multipart_uploads("") do
      now = DateTime.utc_now()

      {:ok,
       [
         %{key: "young.zip", upload_id: "1", started_at: DateTime.add(now, -3_600)},
         %{key: "old.zip", upload_id: "2", started_at: DateTime.add(now, -2 * 86_400)}
       ]}
    end

    def multipart_abort(key, id) do
      send(self(), {:aborted, key, id})
      :ok
    end
  end

  test "multipart uploads older than max_age given up, the younger kept" do
    assert {:ok, 1} = Storehouse.Sweeper.sweep(adapter: Open, expiring: false)
    assert_received {:aborted, "old.zip", "2"}
    refute_received {:aborted, "young.zip", _id}
  end

  test "none given up when asked not to" do
    assert {:ok, 0} = Storehouse.Sweeper.sweep(adapter: Open, expiring: false, multipart: false)
    refute_received {:aborted, _key, _id}
  end
end
