defmodule Graphism.MixProject do
  use Mix.Project

  def project do
    [
      app: :graphism,
      version: "0.2.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :plug_cowboy, :hackney]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:absinthe, "~> 1.6.5"},
      {:absinthe_plug, "~> 1.5"},
      {:calendar, "~> 1.0.0"},
      {:dataloader, "~> 1.0.0"},
      {:ecto_sql, "~> 3.4"},
      {:jason, "~> 1.2"},
      {:inflex, "~> 2.0.0"},
      {:libgraph, "~> 0.13.3"},
      {:plug_cowboy, "~> 2.0"},
      {:postgrex, ">= 0.0.0"},
      {:recase, "~> 0.5"},
      {:telemetry, "~> 1.0", override: true}
    ]
  end
end
