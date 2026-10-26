defmodule Storehouse.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/hattoriai/storehouse"

  def project do
    [
      app: :storehouse,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto],
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
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      # Storehouse.Ecto: files in a record's column. Optional.
      {:ecto, "~> 3.12", optional: true},
      # Storehouse.File as JSON with Jason, beside Elixir's own JSON. Optional.
      {:jason, "~> 1.4", optional: true},
      # Storehouse.Runner.Oban, the runner of Storehouse's jobs in Oban. Optional.
      {:oban, "~> 2.19", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.19", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # The LiveView test client, for Storehouse.Live's tests.
      {:lazy_html, "~> 0.1", only: :test},
      # Storehouse.Live: files of a LiveView upload. Without LiveView, the
      # rest of Storehouse works as it is.
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:plug, "~> 1.15"},
      # HTTP, for S3, fetch/2, purges and warming: Req, on Finch and Mint.
      {:req, "~> 0.5"},
      # Storehouse.Local's signatures (Plug.Crypto.secure_compare/2); 2.2.1
      # and later, for EEF-CVE-2026-105963, in the apps that use Storehouse.
      {:plug_crypto, "~> 2.2 and >= 2.2.1"},
      {:telemetry, "~> 1.0"},
      # The placeholders (Storehouse.Analyzer.Placeholder, ThumbHash, BlurHash)
      # and Storehouse.Renderer.Vix: libvips. Optional.
      {:vix, "~> 0.31", optional: true},
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
        ~w(lib priv/static/storehouse.js priv/static/storehouse.cjs.js priv/static/storehouse-client.mjs priv/static/storehouse-client.d.mts package.json mix.exs .formatter.exs guides README.md CHANGELOG.md LICENSE NOTICE)
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
        "guides/any_client.md",
        "guides/private_files.md",
        "guides/ecto.md",
        "guides/analysis.md",
        "guides/variants.md",
        "guides/background.md",
        "guides/features.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Files: [
          Storehouse,
          Storehouse.File,
          Storehouse.Check,
          Storehouse.ReadError
        ],
        Archives: [
          Storehouse.Archive,
          Storehouse.Archive.Format,
          Storehouse.Archive.Entry,
          Storehouse.Archive.Zip,
          Storehouse.Archive.Tar
        ],
        Stores: [
          Storehouse.Adapter,
          Storehouse.Local,
          Storehouse.Local.Plug,
          Storehouse.S3,
          Storehouse.Mirror
        ],
        Analysis: [
          Storehouse.Analyzer,
          Storehouse.Analysis,
          Storehouse.Analyzer.Size,
          Storehouse.Analyzer.Placeholder,
          Storehouse.Analyzer.ThumbHash,
          Storehouse.Analyzer.BlurHash,
          Storehouse.Analyzer.EditMetadata
        ],
        Images: [
          Storehouse.Image.ThumbHash,
          Storehouse.Image.BlurHash,
          Storehouse.Image.MetadataEditor,
          Storehouse.Image.MetadataEditor.Builtin,
          Storehouse.Image.JPEG,
          Storehouse.Image.PNG,
          Storehouse.Image.WebP
        ],
        Variants: [
          Storehouse.Variants,
          Storehouse.Variants.Plug,
          Storehouse.Variant,
          Storehouse.Responsive,
          Storehouse.Components,
          Storehouse.Analyzer.Warm,
          Storehouse.Renderer,
          Storehouse.Renderer.Vix,
          Storehouse.Renderer.Imgproxy
        ],
        "Work out of the request": [
          Storehouse.Runner,
          Storehouse.Job,
          Storehouse.Runner.Oban,
          Storehouse.Runner.Oban.Worker,
          Storehouse.Runner.Memory
        ],
        Cleanup: [Storehouse.Sweeper],
        Events: [Storehouse.Notify, Storehouse.Notify.PubSub],
        Tests: [Storehouse.Memory, Storehouse.Test],
        "Private files": [Storehouse.Redirect, Storehouse.Proxy],
        "A CDN in front": [Storehouse.Purge, Storehouse.Purge.Cloudflare],
        "Resumable uploads (tus)": [
          Storehouse.Tus.Plug,
          Storehouse.Tus,
          Storehouse.Tus.State,
          Storehouse.Tus.State.ETS
        ],
        "Any client": [
          Storehouse.Batch,
          Storehouse.Plug.Presign,
          Storehouse.Plug.Register,
          Storehouse.Plug.Multipart
        ],
        LiveView: [Storehouse.Live, Storehouse.Live.Writer],
        Ecto: [Storehouse.Ecto, Storehouse.Ecto.File],
        "A library of files": [
          Storehouse.Ecto.Blob,
          Storehouse.Ecto.Blob.Schema,
          Storehouse.Ecto.Usage,
          Storehouse.Ecto.Migrations
        ]
      ]
    ]
  end
end
