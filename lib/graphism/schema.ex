defmodule Graphism.Schema do
  @moduledoc "Generates entity schema modules"

  alias Graphism.{Entity, Migrations}

  def empty_modules(schema) do
    schema
    |> Enum.reject(&Entity.virtual?(&1))
    |> Enum.map(fn e ->
      quote do
        defmodule unquote(e[:schema_module]) do
        end
      end
    end)
  end

  def schema_module(e, schema, _opts) do
    indices = Migrations.indices_from_attributes(e) ++ Migrations.indices_from_keys(e)
    stored_attributes = Enum.reject(e[:attributes], fn attr -> attr[:name] == :id or Entity.virtual?(attr) end)
    scope_columns = Enum.map(e[:opts][:scope] || [], fn col -> String.to_atom("#{col}_id") end)

    quote do
      defmodule unquote(e[:schema_module]) do
        use Ecto.Schema
        import Ecto.Changeset

        def entity, do: unquote(e[:name])

        unquote_splicing(
          e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
          |> Enum.map(fn rel ->
            target = Entity.find_entity!(schema, rel[:target])
            schema_module = target[:schema_module]

            quote do
              alias unquote(schema_module)
            end
          end)
        )

        @primary_key {:id, :binary_id, autogenerate: false}
        @timestamps_opts [type: :utc_datetime]

        schema unquote("#{e[:plural]}") do
          unquote_splicing(
            Enum.map(stored_attributes, fn attr ->
              kind = get_in(attr, [:opts, :schema]) || attr[:kind]
              kind = ecto_datatype(kind)

              case attr[:opts][:default] do
                nil ->
                  quote do
                    Ecto.Schema.field(unquote(attr[:name]), unquote(kind))
                  end

                default ->
                  default = default_value(default)

                  quote do
                    Ecto.Schema.field(unquote(attr[:name]), unquote(kind), default: unquote(default))
                  end
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.map(fn rel ->
              target = Entity.find_entity!(schema, rel[:target])
              schema_module = target[:schema_module]

              case rel[:kind] do
                :belongs_to ->
                  foreign_key = String.to_atom("#{rel[:name]}_id")

                  quote do
                    Ecto.Schema.belongs_to(
                      unquote(rel[:name]),
                      unquote(schema_module),
                      type: :binary_id,
                      foreign_key: unquote(foreign_key)
                    )
                  end

                :has_many ->
                  inverse_rel = Entity.inverse_relation!(schema, e, rel[:name])
                  foreign_key = String.to_atom("#{inverse_rel[:name]}_id")

                  quote do
                    Ecto.Schema.has_many(
                      unquote(rel[:name]),
                      unquote(schema_module),
                      foreign_key: unquote(foreign_key)
                    )
                  end
              end
            end)
          )

          timestamps()
        end

        @required_fields unquote(
                           (e[:attributes]
                            |> Enum.reject(&((Entity.optional?(&1) && !Entity.non_empty?(&1)) || Entity.virtual?(&1)))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e
                              |> Entity.parent_relations()
                              |> Enum.reject(&Entity.optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @optional_fields unquote(
                           (e[:attributes]
                            |> Enum.filter(&Entity.optional?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e[:relations]
                              |> Enum.filter(fn rel ->
                                rel[:kind] == :belongs_to
                              end)
                              |> Enum.filter(&Entity.optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @all_fields @required_fields ++ @optional_fields

        @computed_fields unquote(
                           (e[:attributes] || e[:relations])
                           |> Enum.filter(&Entity.computed?/1)
                           |> Enum.map(fn field ->
                             field[:name]
                           end)
                         )

        def required_fields, do: @required_fields
        def optional_fields, do: @optional_fields
        def computed_fields, do: @computed_fields

        unquote_splicing(
          (Entity.names(stored_attributes) ++ [:inserted_at, :updated_at])
          |> Enum.map(&attribute_field_spec_ast(e, &1, schema))
        )

        unquote_splicing(
          e
          |> Entity.relations()
          |> Entity.names()
          |> Enum.map(&relation_field_spec_ast(e, &1, schema))
        )

        def field_spec(_), do: {:error, :unknown_field}

        unquote_splicing(relation_field_specs_ast(e, schema))

        def field_specs(_), do: []

        unquote_splicing(relation_paths_ast(e, schema))

        def paths_to(_), do: []

        def changeset(e, attrs) do
          changes =
            e
            |> cast(attrs, @all_fields)
            |> validate_required(@required_fields)
            |> unique_constraint(:id, name: unquote("#{e[:table]}_pkey"))

          unquote_splicing(
            e[:attributes]
            |> Enum.filter(fn attr -> attr[:kind] == :string end)
            |> Enum.reject(fn attr -> attr[:opts][:store] == :text end)
            |> Enum.map(fn attr ->
              quote do
                changes =
                  changes
                  |> validate_length(unquote(attr[:name]), max: 255, message: "should be at most 255 characters")
              end
            end)
          )

          unquote_splicing(
            Enum.map(indices, fn index ->
              field_name = (index.columns -- scope_columns) |> Enum.join("_") |> String.to_atom()

              quote do
                changes =
                  changes
                  |> unique_constraint(
                    unquote(field_name),
                    name: unquote(index.name)
                  )
              end
            end)
          )

          unquote_splicing(
            e
            |> Entity.parent_relations()
            |> Enum.map(fn rel ->
              constraint = Migrations.foreign_key_constraint_from_relation(e, rel)
              name = constraint[:name]
              field = constraint[:field]
              message = "referenced data does not exist"

              quote do
                changes =
                  changes
                  |> foreign_key_constraint(
                    unquote(field),
                    name: unquote(name),
                    message: unquote(message)
                  )
              end
            end)
          )
        end

        def delete_changeset(e) do
          changes = e |> cast(%{}, [])

          unquote_splicing(
            # find all relations in the schema that
            # point to this entity
            schema
            |> Enum.flat_map(fn entity ->
              entity[:relations]
              |> Enum.filter(fn rel ->
                rel[:target] == e[:name] &&
                  rel[:kind] == :belongs_to
              end)
              |> Enum.map(fn rel ->
                Keyword.put(rel, :from, entity)
              end)
            end)
            |> Enum.map(fn rel ->
              from_entity = rel[:from][:name]
              from_table = rel[:from][:table]
              name = "#{from_table}_#{e[:name]}_id_fkey"
              message = "not empty"

              quote do
                changes =
                  changes
                  |> foreign_key_constraint(unquote(from_entity),
                    name: unquote(name),
                    message: unquote(message)
                  )
              end
            end)
          )

          changes
        end
      end
    end
  end

  defp ecto_datatype(:datetime), do: :utc_datetime
  defp ecto_datatype(other), do: other

  defp default_value(true), do: true
  defp default_value(false), do: false
  defp default_value(v) when is_atom(v), do: "#{v}"
  defp default_value(v), do: v

  defp attribute_field_spec_ast(e, field, _schema) do
    duck_cased = to_string(field)
    camel_cased = Inflex.camelize(field, :lower)

    {column_name, type} =
      if field in [:inserted_at, :updated_at] do
        {field, :timestamp}
      else
        attr = Entity.attribute!(e, field)
        {attr[:name], attr[:kind]}
      end

    spec = {:ok, type, column_name}

    aliases = Enum.uniq([duck_cased, camel_cased, field])

    quote do
      (unquote_splicing(
         for alias <- aliases do
           quote do
             def field_spec(unquote(alias)), do: unquote(Macro.escape(spec))
           end
         end
       ))
    end
  end

  defp relation_field_spec_ast(e, field, schema) do
    duck_cased = to_string(field)
    camel_cased = Inflex.camelize(field, :lower)

    spec = relation_field_spec(e, field, schema)

    aliases = Enum.uniq([duck_cased, camel_cased, field])

    quote do
      (unquote_splicing(
         for alias <- aliases do
           quote do
             def field_spec(unquote(alias)), do: unquote(Macro.escape(spec))
           end
         end
       ))
    end
  end

  defp relation_field_spec(e, field, schema) do
    rel = Entity.relation!(e, field)
    target_name = rel[:target]
    target = Entity.find_entity!(schema, target_name)
    type = rel[:kind]
    target_schema_module = target[:schema_module]

    case type do
      :has_many ->
        {:ok, type, target_name, target_schema_module}

      :belongs_to ->
        {:ok, type, target_name, target_schema_module, rel[:column]}
    end
  end

  defp relation_field_specs_ast(e, schema) do
    e
    |> Entity.relations()
    |> Enum.group_by(fn rel ->
      kind = rel[:kind]
      schema = Entity.find_entity!(schema, rel[:target])[:schema_module]
      {kind, schema}
    end)
    |> Enum.map(fn {group, rels} ->
      rels =
        Enum.map(rels, fn rel ->
          [:ok | rest] = relation_field_spec(e, rel[:name], schema) |> Tuple.to_list()
          List.to_tuple(rest)
        end)

      quote do
        def field_specs(unquote(Macro.escape(group))) do
          unquote(Macro.escape(rels))
        end
      end
    end)
  end

  defp hierarchy(e, schema) do
    e
    |> Entity.parent_relations()
    |> Enum.reject(fn rel -> rel[:target] == e[:name] end)
    |> Enum.map(fn rel ->
      {
        rel[:name],
        schema
        |> Entity.find_entity!(rel[:target])
        |> hierarchy(schema)
      }
    end)
    |> Enum.into(%{})
  end

  defp hierarchy_paths(tree, []) when map_size(tree) == 0 do
    []
  end

  defp hierarchy_paths(tree, context) when map_size(tree) == 0 do
    [List.to_tuple(context)]
  end

  defp hierarchy_paths(tree, context) do
    Enum.flat_map(tree, fn {parent, ancestors} ->
      hierarchy_paths(ancestors, context ++ [parent])
    end)
  end

  defp paths_to(step, paths) do
    paths
    |> Enum.filter(&Enum.member?(&1, step))
    |> Enum.map(fn path ->
      index = Enum.find_index(path, fn s -> s == step end)
      {path, _} = Enum.split(path, index + 1)
      path
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&length/1)
  end

  defp relation_paths_ast(e, schema) do
    paths =
      e
      |> hierarchy(schema)
      |> hierarchy_paths([])
      |> Enum.map(&Tuple.to_list/1)

    paths
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(fn step ->
      quote do
        def paths_to(unquote(step)) do
          unquote(paths_to(step, paths))
        end
      end
    end)
  end
end
