defmodule Lock.Mixfile do
  use Mix.Project

  def project do
    [ app: :con_cache,
      version: "0.0.1",
      elixir: ">= 0.12.3",
      deps: deps ]
  end

  def application do
    []
  end

  defp deps do
    [{:exactor, "0.2.0", github: "sasa1977/exactor"}]
  end
end
