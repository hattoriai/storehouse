defmodule Storehouse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hattoriai/storehouse"

  def project do
    [
      app: :storehouse,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :inets, :ssl, :public_key],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Storehouse",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    # :inets and :ssl for the files an app lets the server fetch
    # (Storehouse.fetch/2), started when it does.
    [
      extra_applications: [
        :logger,
        :crypto,
        inets: :optional,
        ssl: :optional,
        public_key: :optional
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # The LiveView test client, for Storehouse.Live's tests.
      {:lazy_html, "~> 0.1", only: :test},
      # Storehouse.Live: files of a LiveView upload. Without LiveView, the
      # rest of Storehouse works as it is.
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:plug, "~> 1.15"},
      {:telemetry, "~> 1.0"},
      # A web server for the tests of fetch/2.
      {:bandit, "~> 1.5", only: :test},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    "Files for Phoenix: uploads checked by their bytes, stored under safe keys on the local " <>
      "disk or in a store of your own, and served safely."
  end

  defp package do
    [
      name: "storehouse",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/static/storehouse.js priv/static/storehouse.cjs.js package.json mix.exs .formatter.exs guides README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{"media" => "media"},
      extras: [
        "README.md",
        "guides/stores.md",
        "guides/serving.md",
        "guides/liveview.md",
        "guides/direct_uploads.md",
        "guides/private_files.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Files: [Storehouse, Storehouse.File, Storehouse.Check],
        Stores: [Storehouse.Adapter, Storehouse.Local, Storehouse.Local.Plug, Storehouse.S3],
        "Private files": [Storehouse.Redirect],
        LiveView: [Storehouse.Live]
      ]
    ]
  end
end
