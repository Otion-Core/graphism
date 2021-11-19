defmodule Graphism.Case do
  defmacro __using__(_) do
    quote do
      use ExUnit.Case

      defp mutation(entity, name, schema \\ __MODULE__.Schema) do
        type = String.to_atom("#{entity}_mutations")
        mutations = Absinthe.Schema.lookup_type(schema, type)
        Map.get(mutations.fields, name)
      end

      defp args(mutation), do: mutation.args
      defp arg?(mutation, arg), do: mutation |> args() |> Map.has_key?(arg)
    end
  end
end
