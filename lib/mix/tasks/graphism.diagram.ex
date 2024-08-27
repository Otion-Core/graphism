defmodule Mix.Tasks.Graphism.Diagram do
  @moduledoc """
  A Mix task that generates a diagram for your schema
  """

  use Mix.Task

  @shortdoc """
  A Mix task that generates a diagram for your schema
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

    schema.diagram()
  end
end
