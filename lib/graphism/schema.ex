defmodule Graphism.Schema do
  @moduledoc "Generates entity schema modules"

  alias Graphism.{Ast, Entity, Migrations}

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

  def schema_module(e, schema, repo, graphism_schema) do
    indices = Migrations.indices_from_attributes(e) ++ Migrations.indices_from_keys(e)
    stored_attributes = Enum.reject(e[:attributes], fn attr -> attr[:name] == :id or Entity.virtual?(attr) end)
    stored_relations = Enum.reject(e[:relations], &Entity.virtual?/1)
    scope_columns = Enum.map(e[:opts][:scope] || [], fn col -> String.to_atom("#{col}_id") end)
    schema_module = Keyword.fetch!(e, :schema_module)
    fields_metadata = fields_metadata(e, schema)
    graphism_schema = graphism_schema

    quote do
      defmodule unquote(schema_module) do
        use Ecto.Schema
        import Ecto.Changeset
        import Ecto.Query

        unquote_splicing(slugify_module(e))

        @name unquote(e[:name])

        def entity, do: @name
        def name, do: @name
        def schema, do: unquote(schema_module)
        def repo, do: unquote(repo)

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
            stored_relations
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
                  case rel[:opts][:through] do
                    nil ->
                      inverse_rel = Entity.inverse_relation!(schema, e, rel[:name])
                      foreign_key = String.to_atom("#{inverse_rel[:name]}_id")

                      quote do
                        Ecto.Schema.has_many(
                          unquote(rel[:name]),
                          unquote(schema_module),
                          foreign_key: unquote(foreign_key)
                        )
                      end

                    through ->
                      quote do
                        Ecto.Schema.has_many(
                          unquote(rel[:name]),
                          through: unquote(through)
                        )
                      end
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
                              |> Enum.reject(&Entity.virtual?(&1))
                              |> Enum.reject(&Entity.optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @optional_fields unquote(
                           (e[:attributes]
                            |> Enum.filter(&Entity.optional?(&1))
                            |> Enum.reject(&Entity.virtual?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e
                              |> Entity.parent_relations()
                              |> Enum.reject(&Entity.virtual?(&1))
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

        @fields_metadata unquote(Macro.escape(fields_metadata))

        def required_fields, do: @required_fields
        def optional_fields, do: @optional_fields
        def computed_fields, do: @computed_fields

        def field(name) do
          case Map.get(@fields_metadata, name) do
            nil -> {:error, :unknown_field}
            field -> {:ok, field}
          end
        end

        unquote_splicing(
          (Entity.names(stored_attributes) ++ [:id, :inserted_at, :updated_at])
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

        def shortest_path(field) do
          unquote(graphism_schema).shortest_path(@name, field)
        end

        unquote_splicing(inverse_relation_ast(e, schema))

        defp add_default_if_missing(changeset, attr, value) do
          case get_field(changeset, attr) do
            nil -> put_change(changeset, attr, value)
            _ -> changeset
          end
        end

        def changeset(e, attrs) do
          (unquote_splicing(
             List.flatten([
               fields_changeset_ast(e),
               default_fields_changeset_ast(e),
               max_length_fields_changeset_ast(e),
               unique_constraints_changeset_ast(indices, scope_columns),
               foreign_key_constraints_changeset_ast(e)
             ])
           ))
        end

        def update_changeset(e, attrs) do
          (unquote_splicing(
             List.flatten([
               immutable_fields_changeset_ast(e),
               fields_changeset_ast(e),
               default_fields_changeset_ast(e),
               max_length_fields_changeset_ast(e),
               unique_constraints_changeset_ast(indices, scope_columns),
               foreign_key_constraints_changeset_ast(e)
             ])
           ))
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
              name = "#{from_table}_#{rel[:name]}_id_fkey"
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

        def query, do: from(unquote(Ast.var(e[:name])) in unquote(schema_module), as: unquote(e[:name]))
      end
    end
  end

  defp ecto_datatype(:bigint), do: :integer
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
      cond do
        field == :id ->
          {:field, :string}

        field in [:inserted_at, :updated_at] ->
          {field, :timestamp}

        true ->
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

  defp inverse_relation_ast(e, schema) do
    for rel <- Entity.relations(e) do
      with inverse when inverse != nil <- Entity.inverse_relation(schema, e, rel[:name]) do
        target = Entity.find_entity!(schema, rel[:target])
        schema_module = Keyword.fetch!(target, :schema_module)

        quote do
          def inverse_relation(unquote(rel[:name])) do
            unquote(schema_module).field_spec(unquote(inverse[:name]))
          end
        end
      end
    end ++
      [
        quote do
          def inverse_relation(_) do
            {:error, :unknown}
          end
        end
      ]
  end

  defp immutable_fields_changeset_ast(e) do
    immutable_fields = e[:attributes] |> Enum.filter(&Entity.immutable?/1) |> Entity.names()

    quote do
      attrs = Map.drop(attrs, unquote(immutable_fields))
    end
  end

  defp fields_changeset_ast(e) do
    quote do
      changes =
        e
        |> cast(attrs, @all_fields)
        |> validate_required(@required_fields)
        |> unique_constraint(:id, name: unquote("#{e[:table]}_pkey"))
    end
  end

  defp default_fields_changeset_ast(e) do
    e[:attributes]
    |> Enum.filter(&Entity.optional?/1)
    |> Enum.filter(fn attr -> get_in(attr, [:opts, :default]) end)
    |> Enum.map(fn attr ->
      default_value = get_in(attr, [:opts, :default])

      quote do
        changes = add_default_if_missing(changes, unquote(attr[:name]), unquote(default_value))
      end
    end)
  end

  defp max_length_fields_changeset_ast(e) do
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
  end

  defp unique_constraints_changeset_ast(indices, scope_columns) do
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
  end

  defp foreign_key_constraints_changeset_ast(e) do
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
  end

  defp slugify_module(e) do
    e[:attributes]
    |> Enum.filter(&(&1[:opts][:using] == Entity.slugify_module_name(e[:schema_module])))
    |> Enum.map(fn attr ->
      field = attr[:opts][:using_field]

      quote do
        defmodule Slugify do
          def execute(args, _context) do
            case Map.get(args, unquote(field)) do
              nil ->
                {:error, :invalid}

              value ->
                {:ok, Slug.slugify(value)}
            end
          end
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fields_metadata(e, schema) do
    attributes_metadata = attributes_metadata(e, schema)
    relations_metadata = relations_metadata(e, schema)

    Map.merge(attributes_metadata, relations_metadata)
  end

  defp attributes_metadata(e, _schema) do
    for attr <- e[:attributes], into: %{} do
      attr =
        attr
        |> Keyword.take([:name, :kind])
        |> Keyword.put(:column_name, attr[:name])
        |> Keyword.put(:required?, Entity.required?(attr))
        |> Map.new()

      {attr.name, attr}
    end
  end

  defp relations_metadata(e, schema) do
    for rel <- e[:relations], into: %{} do
      target = Entity.find_entity!(schema, rel[:target])

      target =
        target
        |> Keyword.take([:name])
        |> Keyword.put(:module, target[:schema_module])
        |> Map.new()

      inverse = Entity.inverse_relation_if_exists(schema, e, rel[:name])

      inverse =
        inverse
        |> Keyword.take([:name, :kind, :target])
        |> Keyword.put(:column_name, inverse[:column])
        |> Keyword.put(:source, target[:name])
        |> Map.new()

      rel =
        rel
        |> Keyword.take([:name, :kind])
        |> Keyword.put(:target, target)
        |> Keyword.put(:source, e[:name])
        |> Keyword.put(:inverse, inverse)
        |> Keyword.put(:column_name, rel[:column])
        |> Keyword.put(:required?, Entity.required?(rel))
        |> Map.new()

      {rel.name, rel}
    end
  end
end
