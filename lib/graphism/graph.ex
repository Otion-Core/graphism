defmodule Graphism.Graph do
  @moduledoc """
  Builds a graph from a schema
  """

  alias Graphism.Entity

  def build(schema) do
    graph = Graph.new()

    Enum.reduce(schema, graph, fn entity, g ->
      g
      |> with_entity(entity)
      |> with_attributes(entity)
      |> with_parents(entity)
    end)
  end

  def diagram_fun(graph) do
    {:ok, dot} = Graph.to_dot(graph)

    quote do
      @graph_dot unquote(dot)
      def diagram_source, do: @graph_dot

      def diagram do
        File.write!("diagram.dot", @graph_dot)

        command = "sh"

        args = [
          "-c",
          "dot -Tpng diagram.dot > diagram.png; open diagram.png"
        ]

        with {"", 0} <- System.cmd(command, args), do: :ok
      end
    end
  end

  def graph_fun(graph) do
    quote do
      @graph unquote(Macro.escape(graph))
      def graph, do: @graph
    end
  end

  def shortest_path_fun do
    quote do
      def shortest_path(model_name, field) do
        case Graphism.Graph.vertex(@graph, field) do
          nil ->
            raise "Field #{inspect(field)} is not an attribute nor a parent relation in schema"

          target ->
            @graph
            |> Graph.dijkstra({:model, model_name}, target)
            |> Graphism.Graph.simple_path()
        end
      end
    end
  end

  def paths_fun do
    quote do
      def paths(model_name, field) do
        case Graphism.Graph.vertex(@graph, field) do
          nil ->
            raise "Field #{inspect(field)} is not an attribute nor a parent relation in schema"

          target ->
            @graph
            |> Graph.get_paths({:model, model_name}, target)
            |> Enum.map(&Graphism.Graph.simple_path/1)
        end
      end
    end
  end

  def simple_path(nil), do: []

  def simple_path(path) when is_list(path) do
    path
    |> Enum.map(fn
      {:model, _} -> nil
      {_, field} -> field
    end)
    |> Enum.reject(&is_nil/1)
  end

  def vertex(graph, field) do
    target = {:parent, field}

    cond do
      Graph.has_vertex?(graph, target) ->
        target

      Graph.has_vertex?(graph, {:attribute, field}) ->
        {:attribute, field}

      true ->
        nil
    end
  end

  defp with_entity(graph, entity) do
    Graph.add_vertex(graph, {:model, entity[:name]})
  end

  defp with_attributes(graph, entity) do
    entity
    |> Keyword.get(:attributes, [])
    |> Enum.reduce(graph, fn attr, g ->
      g
      |> Graph.add_vertex({:attribute, attr[:name]})
      |> Graph.add_edge({:model, entity[:name]}, {:attribute, attr[:name]})
    end)
  end

  defp with_parents(graph, entity) do
    entity
    |> Keyword.get(:relations, [])
    |> Enum.filter(&(&1[:kind] == :belongs_to))
    |> Enum.reduce(graph, fn rel, g ->
      weight = if Entity.optional?(rel), do: 2, else: 1

      g
      |> Graph.add_vertex({:parent, rel[:name]})
      |> Graph.add_edge({:model, entity[:name]}, {:parent, rel[:name]}, weight: weight)
      |> Graph.add_edge({:parent, rel[:name]}, {:model, rel[:target]}, weight: weight)
    end)
  end
end
