defmodule Mix.Tasks.Graphism.Gen.Migrations do
  @moduledoc """
  A Mix task that generates all your Ecto migrations
  based on your current Graphism schema
  """

  use Mix.Task

  alias Graphism.Migrations

  @shortdoc """
  A Mix task that generates all your Ecto migrations
  based on your current Graphism schema
  """

  @impl true
  def run(_args) do
    module = GraphismWeb.Schema
    Migrations.generate(module: module)
  end
end
