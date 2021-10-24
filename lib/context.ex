defmodule Graphism.Context do
  @moduledoc "Builds a context from a given entity"

  def from(parent, data) when is_map(data) do
    data
    |> Map.keys()
    |> Enum.reduce(parent, fn key, acc ->
      value = Map.get(data, key)

      case {Map.get(acc, key), is_map(value)} do
        {nil, true} ->
          child = from(%{}, value)
          # stripped = Map.drop(value, Map.keys(child))

          acc
          |> Map.put(key, value)
          |> Map.merge(child)

        _ ->
          acc
      end
    end)
  end

  def from(parent, _), do: parent
end
