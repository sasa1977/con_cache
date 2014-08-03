Code.ensure_loaded?(Hex) and Hex.start

defmodule ConCache.Mixfile do
  use Mix.Project

  @version "0.4.0"

  def project do
    [
      app: :con_cache,
      version: @version,
      elixir: "~> 0.15.0",
      deps: deps,
      package: [
        contributors: ["Saša Jurić"],
        licenses: ["MIT"],
        links: [{"Github", "https://github.com/sasa1977/con_cache"}]
      ],
      description: "ETS based key-value storage with support for row-level isolated writes, TTL auto-purge, and modification callbacks.",
      docs: [
        readme: true,
        main: "README",
        source_url: "https://github.com/sasa1977/con_cache/",
        source_ref: @version
      ]
    ]
  end

  def application do
    [applications: [:exactor], mod: {ConCache.Application, []}]
  end

  defp deps do
    [
      {:exactor, "~> 0.6.0"},
      {:ex_doc, github: "elixir-lang/ex_doc", only: :docs}
    ]
  end
end