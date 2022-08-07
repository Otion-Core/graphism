defmodule Graphism.Encoder do
  @moduledoc "Provides encoder modules for entitites"

  alias Graphism.Entity

  def json_modules(schema) do
    Enum.map(schema, fn e -> json_module(e, schema) end)
  end

  defp json_module(e, _schema) do
    attributes = (e |> Entity.public_attributes() |> Entity.names()) ++ [:inserted_at, :updated_at]

    relations =
      e
      |> Entity.parent_relations()
      |> Enum.map(fn rel -> {rel[:name], rel[:column]} end)

    quote do
      defmodule unquote(e[:json_encoder_module]) do
        defimpl Jason.Encoder, for: unquote(e[:schema_module]) do
          @attributes unquote(attributes)
          @relations unquote(relations)

          def encode(item, opts) do
            item
            |> Map.take(@attributes)
            |> with_relations(@relations, item)
            |> Jason.encode!()
          end

          defp with_relations(dest, rels, source) do
            Enum.reduce(rels, dest, fn {name, col}, d ->
              v = with %Ecto.Association.NotLoaded{} <- Map.get(source, name), do: %{id: Map.get(source, col)}
              Map.put(d, name, v)
            end)
          end
        end
      end
    end
  end
end
