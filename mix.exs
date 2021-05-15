defmodule Graphism.MixProject do
  use Mix.Project

  def project do
    [
      app: :graphism,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:absinthe, "~> 1.5"},
      {:calendar, "~> 1.0.0"},
      {:dataloader, "~> 1.0.0"},
      {:ecto_sql, "~> 3.4"},
      {:inflex, "~> 2.0.0"},
      {:libgraph, "~> 0.13.3"},
      {:recase, "~> 0.5"}
    ]
  end
end
