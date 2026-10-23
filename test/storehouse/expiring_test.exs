defmodule Storehouse.ExpiringTest do
  # Files that expire: their keys, their signed URLs, and the sweep.
  use ExUnit.Case, async: false

  @harbour Path.expand("../fixtures/harbour.jpg", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "storehouse-expiring-#{System.unique_integer([:positive])}")

    Application.put_env(:storehouse, Storehouse.Local,
      root: root,
      secret: String.duplicate("expiring-", 4)
    )

    on_exit(fn ->
      Application.delete_env(:storehouse, Storehouse.Local)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp expires(url),
    do:
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("expires")
      |> String.to_integer()

  test "a file stored to expire: under the prefix, its days rounded up, when it expires in its key" do
    now = System.system_time(:second)
    {:ok, file} = Storehouse.store(@harbour, expires_in: 90_000, owner: "accounts/42")

    assert "expiring/2d/" <> _rest = file.key
    assert_in_delta DateTime.to_unix(Storehouse.expires_at(file)), now + 90_000, 2
    assert Storehouse.owns?("accounts/42", file.key)
    refute Storehouse.owns?("accounts/7", file.key)
    assert {:ok, _bytes} = Storehouse.read(file)

    assert Storehouse.expires_at(Storehouse.key("a.png", "image/png")) == nil

    assert_raise ArgumentError, ~r/not both/, fn ->
      Storehouse.store(@harbour, expires_in: 60, cache: true)
    end
  end

  test "its signed URL never outlives it, and it has none once expired" do
    {:ok, file} = Storehouse.store(@harbour, expires_in: 60)

    {:ok, url} = Storehouse.signed_url(file, expires_in: 3_600)
    assert expires(url) <= System.system_time(:second) + 60

    {:ok, url} = Storehouse.signed_url(file, expires_in: 10)
    assert expires(url) <= System.system_time(:second) + 10

    past = Storehouse.expiring_key("exports/old.zip", 10, DateTime.add(DateTime.utc_now(), -60))
    assert Storehouse.signed_url(past) == {:error, :expired}
  end

  test "the sweeper deletes the files that expired, and only those", %{root: root} do
    write = fn key ->
      path = Path.join(root, key)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x")
      key
    end

    past = DateTime.add(DateTime.utc_now(), -3_600)
    expired = write.(Storehouse.expiring_key("exports/a.zip", 60, past))
    later = write.(Storehouse.expiring_key("exports/b.zip", 86_400))
    kept = write.("exports/c.zip")

    assert Storehouse.Sweeper.sweep(expiring: false) == {:ok, 0}
    assert File.exists?(Path.join(root, expired))

    assert Storehouse.Sweeper.sweep() == {:ok, 1}
    refute File.exists?(Path.join(root, expired))
    assert File.exists?(Path.join(root, later))
    assert File.exists?(Path.join(root, kept))
  end

  test "an upload straight to the store keeps :expires_in for its URL" do
    {:ok, upload} = Storehouse.presign_upload("a.png", "image/png", 10, expires_in: 60)
    refute upload.key =~ "expiring/"
  end
end
