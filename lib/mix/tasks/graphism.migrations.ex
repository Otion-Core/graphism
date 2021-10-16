defmodule Mix.Tasks.Graphism.Migrations do
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
    Mix.Task.run("compile")

    schema = Application.get_env(:graphism, :schema)

    unless schema do
      raise """
        Please specify your graphism schema, eg:

        config :graphism, schema: Your.Schema
      """
    end

    Migrations.generate(module: schema)
  end
end
