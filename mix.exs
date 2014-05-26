Code.ensure_loaded?(Hex) and Hex.start

defmodule Lock.Mixfile do
  use Mix.Project

  def project do
    [
      app: :con_cache,
      version: "0.1.0",
      elixir: "~> 0.13.3",
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
    [{:exactor, "~> 0.4.0"}]
  end
end
