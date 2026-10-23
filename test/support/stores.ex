defmodule StorehouseTest.PrivateFiles do
  @moduledoc "A second local store, for the tests of named stores."
  use Storehouse.Local
end

defmodule StorehouseTest.Scratch do
  @moduledoc "A third local store, its config under another app."
  use Storehouse.Local, otp_app: :storehouse_test
end

defmodule StorehouseTest.Media do
  @moduledoc "A second S3 store: another bucket."
  use Storehouse.S3
end
