Code.ensure_loaded?(Hex) and Hex.start()

defmodule ConCache.Mixfile do
  use Mix.Project

  @version "0.14.0"

  def project do
    [
      app: :con_cache,
      version: @version,
      elixir: "~> 1.7",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [
        maintainers: ["Saša Jurić"],
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/sasa1977/con_cache",
          "Docs" => "http://hexdocs.pm/con_cache",
          "Changelog" =>
            "https://github.com/sasa1977/con_cache/blob/#{@version}/CHANGELOG.md#v#{
              String.replace(@version, ".", "")
            }"
        }
      ],
      description:
        "ETS based key-value storage with support for row-level isolated writes, TTL auto-purge, and modification callbacks.",
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
      {:ex_doc, "~> 0.19.0", only: :dev},
      {:dialyxir, "~> 0.5.0", only: :dev}
    ]
  end
end
