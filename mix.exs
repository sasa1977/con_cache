Code.ensure_loaded?(Hex) and Hex.start

defmodule Lock.Mixfile do
  use Mix.Project

  def project do
    [
      app: :con_cache,
      version: "0.2.0",
      elixir: "~> 0.14.3",
      deps: deps,
      package: [
        contributors: ["Saša Jurić"],
        licenses: ["MIT"],
        links: [{"Github", "https://github.com/sasa1977/con_cache"}]
      ],
      description: "ETS based key-value storage with support for row-level isolated writes, TTL auto-purge, and modification callbacks."
    ]
  end

  def application do
    []
  end

  defp deps do
    [{:exactor, "~> 0.5.0"}]
  end
end
