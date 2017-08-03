Code.ensure_loaded?(Hex) and Hex.start

defmodule ConCache.Mixfile do
  use Mix.Project

  @version "0.12.1"

  def project do
    [
      app: :con_cache,
      version: @version,
      elixir: "~> 1.4",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps(),
      package: [
        maintainers: ["Saša Jurić"],
        licenses: ["MIT"],
        links: %{
          "Github" => "https://github.com/sasa1977/con_cache",
          "Docs" => "http://hexdocs.pm/con_cache",
          "Changelog" => "https://github.com/sasa1977/con_cache/blob/#{@version}/CHANGELOG.md#v#{String.replace(@version, ".", "")}"
        }
      ],
      description: "ETS based key-value storage with support for row-level isolated writes, TTL auto-purge, and modification callbacks.",
      docs: [
        extras: ["README.md"],
        main: "ConCache",
        source_url: "https://github.com/sasa1977/con_cache/",
        source_ref: @version
      ]
    ]
  end

  def application do
    [applications: [:logger], mod: {ConCache.Application, []}]
  end

  defp deps do
    [
      {:exactor, "~> 2.2.0"},
      {:ex_doc, "~> 0.14.0", only: :dev}
    ]
  end
end
