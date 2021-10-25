defmodule Graphism.Context do
  @moduledoc "Builds a context from a given entity"

  @ignore_keys [:__struct__, :__cardinality__, :__field__, :__meta__]
  @default_opts [strip: false, simple_fields: true]

  def from(parent, data), do: from(parent, data, @default_opts)

  def from(parent, data, opts) when is_map(data) do
    data
    |> Map.keys()
    |> Enum.reject(&Enum.member?(@ignore_keys, &1))
    |> Enum.reduce(parent, fn key, acc ->
      value = Map.get(data, key)

      case {Map.get(acc, key), is_map(value)} do
        {nil, true} ->
          value = as_map(value)
          child = from(%{}, value)

          value =
            case opts[:strip] do
              true ->
                Map.drop(value, Map.keys(child))

              false ->
                value
            end

          child
          |> Map.merge(acc)
          |> Map.put(key, value)

        _ ->
          acc
      end
    end)
  end

  def from(parent, _, _), do: parent

  defp as_map(data) do
    case Map.has_key?(data, :__struct__) do
      true -> Map.from_struct(data)
      false -> data
    end
    |> Map.drop(@ignore_keys)
  end
end
