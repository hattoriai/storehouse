defmodule Storehouse.PackageTest do
  # The npm package (package.json): @hattoriai/storehouse, of the same
  # version as the Hex package, with every file it names.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @package @root |> Path.join("package.json") |> File.read!() |> Storehouse.JSON.decode!()

  test "is @hattoriai/storehouse, of the Hex package's version" do
    assert @package["name"] == "@hattoriai/storehouse"
    assert @package["version"] == Mix.Project.config()[:version]
    assert @package["publishConfig"] == %{"access" => "public"}
  end

  test "every file it names, and every one it exports, is there" do
    exported =
      for {_path, targets} <- @package["exports"],
          {_condition, file} <- targets,
          do: file

    for file <- @package["files"] ++ exported ++ [@package["main"], @package["module"]] do
      assert File.exists?(Path.join(@root, file)),
             "package.json names #{file}, which is not there"
    end

    for {_path, targets} <- @package["exports"], {_condition, file} <- targets do
      assert String.trim_leading(file, "./") in @package["files"],
             "#{file} is exported but not in files"
    end
  end

  # A Phoenix app imports the JavaScript from deps/storehouse: the Hex
  # package must carry every file the npm one does.
  test "the Hex package carries every file of the npm package" do
    hex = Mix.Project.config()[:package][:files]

    for file <- @package["files"] -- ["README.md", "LICENSE"] do
      assert Enum.any?(hex, &(file == &1 or String.starts_with?(file, &1 <> "/"))),
             "#{file} is in package.json's files but not in mix.exs's package files"
    end
  end
end
