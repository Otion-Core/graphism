defmodule Graphism.Case do
  defmacro __using__(_) do
    quote do
      use ExUnit.Case

      defp mutation(entity, name, schema \\ __MODULE__.Schema) do
        field(entity, :mutations, name, schema)
      end

      defp mutation!(entity, name, schema \\ __MODULE__.Schema) do
        field!(entity, :mutations, name, schema)
      end

      defp query(entity, name, schema \\ __MODULE__.Schema) do
        field(entity, :queries, name, schema)
      end

      defp query!(entity, name, schema \\ __MODULE__.Schema) do
        field!(entity, :queries, name, schema)
      end

      defp field!(entity, kind, name, schema \\ __MODULE__.Schema) do
        field = field(entity, kind, name, schema)

        unless field do
          raise "no such field #{name} (under #{kind}) for #{entity} in #{inspect(schema)}"
        end

        field
      end

      defp field(entity, kind, name, schema \\ __MODULE__.Schema) do
        type_name = String.to_atom("#{entity}_#{kind}")
        type = Absinthe.Schema.lookup_type(schema, type_name)

        unless type do
          raise "no #{kind} for #{entity} in #{inspect(schema)}"
        end

        Map.get(type.fields, name)
      end

      defp args(field), do: field.args
      defp arg?(field, arg), do: field |> args() |> Map.has_key?(arg)
    end
  end
end
