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
    Mix.Task.run("app.start")

    schema = Application.get_env(:graphism, :schema)
    Migrations.generate(module: schema)
  end
end
