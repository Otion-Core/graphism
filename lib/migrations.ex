defmodule Graphism.Migrations do
  @moduledoc """
  A database migrations generator based on a
  Graphism schema
  """
  require Logger

  @doc """
  Generate migrations for the given schema.

  """
  def generate(opts) do
    default_opts = [
      dir: Path.join([File.cwd!(), "priv/repo/migrations"]),
      write_to_disk: true
    ]

    opts = Keyword.merge(default_opts, opts)
    mod = Keyword.fetch!(opts, :module)
    schema = mod.schema()
    enums = mod.enums()

    existing_migrations =
      (opts[:files] ||
         Path.join([opts[:dir], "*_graphism_*.exs"])
         |> Path.wildcard()
         |> Enum.sort()
         |> Enum.map(&File.read!(&1)))
      |> Enum.map(&Code.string_to_quoted!(&1))

    last_migration_version = last_migration_version(existing_migrations)

    existing_migrations =
      existing_migrations
      |> read_migrations()
      |> reduce_migrations()

    missing_migrations =
      missing_migrations(
        existing_migrations,
        schema,
        enums
      )

    write_migration(missing_migrations, last_migration_version + 1, opts)
  end

  defp without_nils(enum) do
    Enum.reject(enum, &is_nil(&1))
  end

  defp virtual?(e) do
    Enum.member?(e[:opts][:modifiers] || [], :virtual)
  end

  defp migration_from_schema(schema, enums) do
    # Index all entities, so that we can figure out foreign keys
    # using plurals and table names from referenced entities
    index =
      schema
      |> Enum.reject(&virtual?(&1))
      |> Enum.reduce(%{}, fn e, acc ->
        Map.put(acc, e[:name], e)
      end)

    migration = %{
      __enums:
        Enum.reduce(enums, %{}, fn {enum, values}, acc ->
          Map.put(acc, enum, values)
        end)
    }

    Enum.reduce(index, migration, fn {_, entity}, acc ->
      migration_from_entity(entity, index, acc)
    end)
  end

  defp migration_from_entity(e, index, acc) do
    # convert entity attributes as simple columns
    # to be added to the table migrations
    m =
      Enum.reduce(e[:attributes], %{}, fn attr, m ->
        name = column_name_from_attribute(attr)
        type = column_type_from_attribute(attr)
        opts = column_opts_from_attribute(attr)

        Map.put(m, name, %{
          type: type,
          opts: opts
        })
      end)

    # convert entity relations as foreign keys
    # to be added to the table migrations
    m =
      e[:relations]
      |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
      |> Enum.reduce(m, fn rel, m ->
        name = column_name_from_relation(rel)
        opts = column_opts_from_relation(rel, index)

        Map.put(m, name, %{
          type: :uuid,
          opts: opts
        })
      end)

    indices =
      (indices_from_attributes(e) ++ indices_from_keys(e))
      |> Enum.reduce(%{}, fn index, acc ->
        Map.put(acc, index[:name], index)
      end)

    Map.put(acc, e[:table], %{
      columns: m,
      indices: indices
    })
  end

  defp indices_from_attributes(e) do
    e[:attributes]
    |> Enum.filter(&unique?(&1))
    |> Enum.map(&index_from_attribute(&1, e))
  end

  defp indices_from_keys(e) do
    Enum.map(e[:keys], &index_from_key(&1, e))
  end

  # Resolve an entity by name. This function raises an error
  # if no such entity was found
  defp entity!(index, name) do
    e = Map.get(index, name)

    unless e do
      raise "Could not resolve entity #{name}: #{inspect(Map.keys(index))}"
    end

    e
  end

  defp column_name_from_relation(name) when is_atom(name) do
    String.to_atom("#{name}_id")
  end

  defp column_name_from_relation(rel) when is_list(rel) do
    column_name_from_relation(rel[:name])
  end

  defp column_opts_from_relation(rel, index) do
    target = entity!(index, rel[:target])
    referenced_tabled = target[:table]
    [null: optional?(rel), references: referenced_tabled]
  end

  defp column_opts_from_attribute(attr) do
    []
    |> column_opts_with_primary_key(attr)
    |> column_opts_with_null(attr)
    |> column_opts_with_default(attr)
    |> column_opts_with_unique(attr)
    |> column_opts_with_stored_type(attr)
  end

  defp column_opts_with_primary_key(opts, attr) do
    case attr[:name] do
      :id ->
        Keyword.put(opts, :primary_key, true)

      _ ->
        opts
    end
  end

  defp optional?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :optional)
  end

  defp unique?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :unique)
  end

  defp column_opts_with_null(opts, attr) do
    case optional?(attr) do
      false ->
        Keyword.put(opts, :null, false)

      true ->
        opts
    end
  end

  defp column_opts_with_default(opts, attr) do
    case attr[:opts][:default] do
      nil ->
        opts

      default ->
        default =
          case is_atom(default) do
            true ->
              Atom.to_string(default)

            false ->
              default
          end

        Keyword.put(opts, :default, default)
    end
  end

  defp column_opts_with_unique(opts, attr) do
    Keyword.put(opts, :unique, unique?(attr))
  end

  defp column_opts_with_stored_type(opts, attr) do
    case attr[:opts][:store] do
      nil -> opts
      stored_type -> Keyword.put(opts, :store, stored_type)
    end
  end

  defp column_type_from_attribute(attr) do
    kind = attr[:kind]

    unless kind do
      raise "entity attribute #{inspect(attr)} has no kind"
    end

    cond do
      :id == kind ->
        :uuid

      nil != attr[:opts][:one_of] ->
        attr[:opts][:one_of]

      true ->
        kind
    end
  end

  defp column_name_from_attribute(attr) do
    attr[:name]
  end

  defp entity_from_table_name!(table, schema) do
    e = Enum.find(schema, fn e -> e[:table] == table end)

    unless e do
      raise "No entity found for table #{table} in #{inspect(schema)}"
    end

    e
  end

  defp attribute_from_column_name!(column, e) do
    attr = Enum.find(e[:attributes], fn attr -> attr[:name] == column end)

    unless attr do
      raise "No attribute for column #{column} found in #{inspect(e)}"
    end

    attr
  end

  defp index_from_attribute(attr, e) do
    case e[:opts][:scope] do
      nil ->
        column_name = column_name_from_attribute(attr)
        index_for(e, [column_name])

      rels ->
        scope_columns = Enum.map(rels, &column_name_from_relation(&1))
        column_name = column_name_from_attribute(attr)

        index_for(e, scope_columns ++ [column_name])
    end
  end

  defp index_from_key(key, e), do: index_for(e, key[:fields])

  defp index_for(e, columns) do
    table = e[:table]
    column_names = Enum.join(columns, "_")
    index_name = String.to_atom("unique_#{column_names}_in_#{table}")
    %{table: table, name: index_name, columns: columns}
  end

  defp missing_migrations(existing, schema, enums) do
    schema_migration = migration_from_schema(schema, enums)

    existing_enums = existing[:__enums]
    schema_enums = schema_migration[:__enums]
    schema_migration = Map.drop(schema_migration, [:__enums])
    existing = Map.drop(existing, [:__enums])

    empty_migration()
    |> without_old_indices(existing, schema_migration)
    |> without_old_columns(existing, schema_migration)
    |> without_old_tables(existing, schema_migration)
    |> without_old_enums(existing_enums, schema_enums)
    |> with_new_enums(existing_enums, schema_enums)
    |> with_new_tables(existing, schema_migration)
    |> with_new_columns(existing, schema_migration, schema)
    |> with_new_indices(existing, schema_migration)
    |> without_old_indices(existing, schema_migration)
    |> with_existing_columns_modified(existing, schema_migration, schema)
    |> with_existing_enums_modified(existing_enums, schema_enums)
  end

  defp empty_migration, do: []

  defp with_new_enums(migrations, existing_enums, schema_enums) do
    enums_to_create = Map.keys(schema_enums) -- Map.keys(existing_enums)

    migrations ++
      Enum.map(enums_to_create, fn enum ->
        create_enum_migration(enum, schema_enums[enum])
      end)
  end

  defp with_existing_enums_modified(migrations, existing_enums, schema_enums) do
    enums_to_modify = Map.keys(schema_enums) -- Map.keys(schema_enums) -- Map.keys(existing_enums)

    migrations ++
      (enums_to_modify
       |> Enum.map(fn enum ->
         case schema_enums[enum] -- existing_enums[enum][:values] do
           [] ->
             nil

           new_values ->
             Enum.map(new_values, fn value -> %{enum: enum, value: value} end)
         end
       end)
       |> without_nils()
       |> List.flatten()
       |> Enum.map(fn %{enum: enum, value: value} ->
         alter_enum_migration(enum, value)
       end))
  end

  defp with_new_tables(migrations, existing, schema) do
    tables_to_create = Map.keys(schema) -- Map.keys(existing)

    migrations ++
      Enum.map(tables_to_create, fn table ->
        create_table_migration(table, schema)
      end)
  end

  defp with_new_indices(migrations, existing, schema) do
    existing_indices = existing |> Enum.flat_map(fn {_, spec} -> spec.indices end) |> Enum.into(%{})
    schema_indices = schema |> Enum.flat_map(fn {_, spec} -> spec.indices end) |> Enum.into(%{})
    new_indices = Map.keys(schema_indices) -- Map.keys(existing_indices)

    migrations ++
      Enum.map(new_indices, fn name ->
        index = schema_indices[name]
        create_index_migration(index)
      end)
  end

  defp without_old_indices(migrations, existing, schema) do
    existing_indices = existing |> Enum.flat_map(fn {_, spec} -> spec.indices end) |> Enum.into(%{})
    schema_indices = schema |> Enum.flat_map(fn {_, spec} -> spec.indices end) |> Enum.into(%{})
    old_indices = Map.keys(existing_indices) -- Map.keys(schema_indices)

    migrations ++
      Enum.map(old_indices, fn name ->
        index = existing_indices[name]
        drop_index_migration(index)
      end)
  end

  defp column_stored_type(column) do
    column[:opts][:store] || column[:type]
  end

  defp with_new_columns(migrations, existing_migration, schema_migration, _schema) do
    tables_to_merge = Map.keys(schema_migration) -- Map.keys(schema_migration) -- Map.keys(existing_migration)

    migrations ++
      (tables_to_merge
       |> Enum.flat_map(fn table ->
         existing_columns = Map.keys(existing_migration[table][:columns])
         schema_columns = Map.keys(schema_migration[table][:columns])

         case schema_columns -- existing_columns do
           [] ->
             []

           columns_to_add ->
             columns_migration =
               Enum.map(columns_to_add, fn col ->
                 column = schema_migration[table][:columns][col]

                 %{
                   column: col,
                   type: column_stored_type(column),
                   opts: column[:opts],
                   action: :add,
                   kind: :column
                 }
               end)

             [alter_table_migration(table, to_add: columns_migration)]
         end
       end)
       |> without_nils())
  end

  defp without_old_columns(migrations, existing_migration, schema_migration) do
    tables_to_merge = Map.keys(schema_migration) -- Map.keys(schema_migration) -- Map.keys(existing_migration)

    migrations ++
      (tables_to_merge
       |> Enum.flat_map(fn table ->
         existing_columns = Map.keys(existing_migration[table][:columns])
         schema_columns = Map.keys(schema_migration[table][:columns])

         case existing_columns -- schema_columns do
           [] ->
             []

           columns_to_remove ->
             [alter_table_migration(table, to_remove: columns_to_remove)]
         end
       end)
       |> without_nils())
  end

  defp without_old_enums(migrations, existing_enums, schema_enums) do
    enums_to_drop = Map.keys(existing_enums) -- Map.keys(schema_enums)

    migrations ++
      Enum.map(enums_to_drop, fn enum ->
        drop_enum_migration(enum, existing_enums[enum])
      end)
  end

  defp without_old_tables(migrations, existing, schema) do
    tables_to_drop = Map.keys(existing) -- Map.keys(schema)

    migrations ++
      Enum.map(tables_to_drop, fn table ->
        drop_table_migration(table)
      end)
  end

  defp with_existing_columns_modified(migrations, existing_migration, schema_migration, schema) do
    tables_to_merge = Map.keys(schema_migration) -- Map.keys(schema_migration) -- Map.keys(existing_migration)

    migrations ++
      (tables_to_merge
       |> Enum.flat_map(fn table ->
         existing_columns = Map.keys(existing_migration[table][:columns])
         schema_columns = Map.keys(schema_migration[table][:columns])

         case schema_columns -- schema_columns -- existing_columns do
           [] ->
             nil

           columns_to_modify ->
             column_migration =
               Enum.map(columns_to_modify, fn col ->
                 existing_column = existing_migration[table][:columns][col]
                 schema_column = schema_migration[table][:columns][col]

                 %{column: col, type: nil, opts: []}
                 |> with_column_type_change(existing_column, schema_column)
                 |> with_column_null_change(existing_column, schema_column)
                 |> with_modify_action_or_nil(schema_column)
                 |> with_column_kind()
               end)
               |> without_nils()
               |> case do
                 [] ->
                   nil

                 columns_to_modify ->
                   alter_table_migration(table, to_modify: columns_to_modify)
               end

             index_migrations =
               columns_to_modify
               |> Enum.filter(&(!schema_migration[table][:columns][&1][:opts][:references]))
               |> Enum.map(fn col ->
                 schema_column = schema_migration[table][:columns][col]

                 existing_indices = existing_migration[table][:indices]
                 entity = entity_from_table_name!(table, schema)

                 column_unique_change(col, existing_indices, schema_column, entity)
               end)

             [column_migration | index_migrations]
         end
         |> without_nils()
       end)
       |> without_nils())
  end

  defp cast?(_from, to), do: to != :string

  defp with_column_type_change(col, existing, schema) do
    stored_type = column_stored_type(schema)

    if existing[:type] != stored_type do
      col
      |> Map.put(:type, stored_type)
      |> Map.put(:cast, cast?(existing[:type], stored_type))
    else
      col
    end
  end

  defp with_column_null_change(col, existing, schema) do
    case {existing[:opts][:null], schema[:opts][:null]} do
      {false, nil} ->
        put_in(col, [:opts, :null], true)

      {nil, false} ->
        put_in(col, [:opts, :null], false)

      _ ->
        col
    end
  end

  defp column_unique_change(col, indices, schema_column, entity) do
    index =
      col
      |> attribute_from_column_name!(entity)
      |> index_from_attribute(entity)

    index_exists? = indices[index[:name]] != nil

    case {schema_column[:opts][:unique] || false, index_exists?} do
      {false, true} ->
        drop_index_migration(index)

      {true, false} ->
        create_index_migration(index)

      _ ->
        nil
    end
  end

  defp with_modify_action_or_nil(col, schema) do
    cond do
      Enum.empty?(col[:opts]) == false ->
        col
        |> Map.put(:type, schema[:type])
        |> Map.put(:action, :modify)

      col[:type] ->
        Map.put(col, :action, :modify)

      true ->
        nil
    end
  end

  defp with_column_kind(nil), do: nil
  defp with_column_kind(col), do: Map.put(col, :kind, :column)

  defp create_table_migration(name, schema) do
    %{
      table: name,
      action: :create,
      kind: :table,
      columns:
        Enum.map(schema[name][:columns], fn {col, spec} ->
          # if the column matches an attribute that contains
          # a one_of option, then we actually want to use
          # a database enum
          migration_from_column(col, spec, :add)
        end)
    }
  end

  defp create_index_migration(index) do
    index_migration(index, :create)
  end

  defp drop_index_migration(index) do
    index_migration(index, :drop)
  end

  defp index_migration(index, action) do
    %{
      index: index[:name],
      action: action,
      kind: :index,
      table: index[:table],
      columns: index[:columns]
    }
  end

  defp drop_table_migration(name) do
    %{table: name, action: :drop, kind: :table}
  end

  defp create_enum_migration(enum, values) do
    %{enum: enum, action: :create, kind: :enum, values: values}
  end

  defp drop_enum_migration(enum, values) do
    %{enum: enum, action: :drop, kind: :enum, values: values}
  end

  defp alter_enum_migration(enum, value) do
    %{enum: enum, action: :alter, kind: :enum, value: value}
  end

  defp alter_table_migration(name, columns) do
    %{
      table: name,
      action: :alter,
      kind: :table,
      columns:
        Enum.map(columns[:to_add] || [], fn col ->
          %{column: col[:column], type: col[:type], opts: col[:opts], action: :add, kind: :column}
        end) ++
          Enum.map(columns[:to_remove] || [], fn col ->
            %{column: col, action: :remove, kind: :column}
          end) ++
          Enum.map(columns[:to_modify] || [], fn col ->
            %{
              column: col[:column],
              type: col[:type],
              opts: col[:opts],
              action: :modify,
              kind: :column,
              cast: col[:cast]
            }
          end)
    }
  end

  defp migration_from_column(col, spec, action) do
    %{column: col, type: spec[:type], opts: spec[:opts], action: action, kind: :column}
  end

  defp read_migrations(migrations) do
    migrations
    |> Enum.flat_map(&parse_migration(&1))
  end

  defp reduce_migrations(migrations) do
    migrations
    |> Enum.reduce(%{__enums: %{}}, &reduce_migration(&1, &2))
  end

  defp reduce_migration(
         %{table: t, action: :drop_if_exists, kind: :table, opts: _, columns: _},
         acc
       ) do
    Map.drop(acc, [t])
  end

  defp reduce_migration(%{table: t, action: :create, kind: :table, opts: _, columns: cols}, acc) do
    # Since this is a create table migration,
    # all columns must be present. We just need to remove the
    # action on each column
    cols =
      Enum.reduce(cols, %{}, fn {name, spec}, acc ->
        Map.put(acc, name, Map.drop(spec, [:action]))
      end)

    # Then replace the resulting table columns
    # in our accumulator
    Map.put(acc, t, %{indices: %{}, columns: cols})
  end

  defp reduce_migration(
         %{index: name, action: :create, kind: :index, table: table, columns: columns},
         acc
       ) do
    t = Map.get(acc, table)

    unless t do
      raise "Index #{name} references unknown table #{table}: #{inspect(Map.keys(acc))}"
    end

    %{indices: indices} = t

    indices =
      Map.put(indices, name, %{
        name: name,
        table: table,
        columns: columns
      })

    t = Map.put(t, :indices, indices)
    Map.put(acc, table, t)
  end

  defp reduce_migration(
         %{index: name, action: :drop_if_exists, kind: :index, table: table, columns: _},
         acc
       ) do
    t = Map.get(acc, table)

    unless t do
      raise "Index #{name} references unknown table #{table}: #{inspect(Map.keys(acc))}"
    end

    %{indices: indices} = t

    indices = Map.drop(indices, [name])
    t = Map.put(t, :indices, indices)
    Map.put(acc, table, t)
  end

  defp reduce_migration(
         %{table: t, action: :alter, kind: :table, opts: _, columns: column_changes} = spec,
         acc
       ) do
    table = Map.get(acc, t)

    # Ensure the table is already present in our current
    # set of migrations. Otherwise, this is a bug. Maybe the migrations
    # are not properly sorted, or there is a missing migration
    unless table do
      raise "Error reading migrations. Trying to alter non existing table: #{inspect(spec)}"
    end

    # Reduce the column changeset on top of the existing columns
    # We either drop columns, add new ones, or renaming existing or
    # change their types
    new_columns =
      column_changes
      |> Enum.reduce(table[:columns], fn {col, change}, cols ->
        case change[:action] do
          :remove ->
            Map.drop(cols, [col])

          :add ->
            Map.put(cols, col, %{
              type: change[:type],
              opts: change[:opts]
            })

          :modify ->
            existing = cols[col]

            unless existing do
              raise "missing column with name #{col} in #{inspect(cols)}. This is a bug!"
            end

            Map.put(cols, col, %{
              type: change[:type],
              opts: Keyword.merge(existing[:opts], change[:opts])
            })
        end
      end)

    # Then replace the resulting table columns
    # in our accumulator
    put_in(acc, [t, :columns], new_columns)
  end

  defp reduce_migration(%{enum: enum, action: :create, kind: :enum, values: values}, acc) do
    put_in(acc, [:__enums, enum], %{enum: enum, values: values})
  end

  defp reduce_migration(%{enum: enum, action: :add_value, kind: :enum, values: value}, acc) do
    key = [:__enums, enum]

    enum_attrs = get_in(acc, key)

    unless enum_attrs do
      raise "No enum attributes found in #{inspect(acc)} at #{inspect(key)}. This is a bug!"
    end

    put_in(acc, key, %{enum_attrs | values: enum_attrs.values ++ [value]})
  end

  defp reduce_migration(%{enum: enum, action: :drop, kind: :enum, values: _}, acc) do
    enums =
      acc[:__enums]
      |> Map.drop([enum])

    Map.put(acc, :__enums, enums)
  end

  defp last_migration_version(migrations) do
    migrations
    |> Enum.take(-1)
    |> migration_version()
  end

  defp migration_version([]), do: 0

  defp migration_version([
         {:defmodule, _,
          [
            {:__aliases__, _, module},
            _
          ]}
       ]) do
    [version] =
      module
      |> Enum.take(-1)

    version =
      version
      |> Atom.to_string()
      |> String.replace_prefix("V", "")
      |> String.to_integer()

    version
  end

  defp parse_migration(
         {:defmodule, _,
          [
            {:__aliases__, _, _},
            [
              do:
                {:__block__, [],
                 [
                   {:use, _, [{:__aliases__, _, [:Ecto, :Migration]}]},
                   {:def, _,
                    [
                      {:up, _, nil},
                      [
                        do: {:__block__, [], up}
                      ]
                    ]},
                   {:def, _,
                    [
                      {:down, _, nil},
                      [do: _]
                    ]}
                 ]}
            ]
          ]}
       ) do
    Enum.map(up, &parse_up(&1))
    |> Enum.reject(fn item -> item == [] end)
  end

  defp parse_migration(
         {:defmodule, _,
          [
            {:__aliases__, _, _},
            [
              do:
                {:__block__, [],
                 [
                   {:use, _, [{:__aliases__, _, [:Ecto, :Migration]}]},
                   {:def, _,
                    [
                      {:up, _, nil},
                      [
                        do: up
                      ]
                    ]},
                   {:def, _,
                    [
                      {:down, _, nil},
                      [do: _]
                    ]}
                 ]}
            ]
          ]}
       ) do
    [parse_up(up)]
    |> Enum.reject(fn item -> item == [] end)
  end

  defp parse_migration({:defmodule, _, [{:__aliases__, _, migration}, _]}) do
    Logger.warn("Unable to parse migration #{Enum.join(migration, ".")}")
    []
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: {:__block__, [], changes}
            ]
          ]}
       ) do
    table_change(table, action, [], changes)
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: change
            ]
          ]}
       ) do
    table_change(table, action, [], [change])
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table, opts]},
            [
              do: {:__block__, [], changes}
            ]
          ]}
       ) do
    table_change(table, action, opts, changes)
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table, opts]},
            [
              do: change
            ]
          ]}
       ) do
    table_change(table, action, opts, [change])
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]}
          ]}
       ) do
    table_change(table, action, [], [])
  end

  defp parse_up(
         {action, _,
          [
            {:unique_index, _, [table, columns, opts]}
          ]}
       ) do
    index_change(table, action, columns, opts)
  end

  defp parse_up(
         {action, _,
          [
            {:index, _, [table, columns, opts]}
          ]}
       ) do
    index_change(table, action, columns, opts)
  end

  defp parse_up(
         {:execute, _,
          [
            "create type " <> enum_expr
          ]}
       ) do
    {enum, values} = parse_enum_expression(enum_expr)
    enum_change(enum, :create, values)
  end

  defp parse_up(
         {:execute, _,
          [
            "alter type " <> enum_expr
          ]}
       ) do
    {enum, value} = parse_enum_add_value_expression(enum_expr)
    enum_change(enum, :add_value, value)
  end

  defp parse_up(
         {:execute, _,
          [
            "drop type " <> enum
          ]}
       ) do
    enum
    |> String.to_atom()
    |> enum_change(:drop, nil)
  end

  defp parse_up(
         {:execute, _,
          [
            "alter table " <> _
          ]}
       ) do
    []
  end

  defp parse_up(other) do
    Logger.warn(
      "Unable to parse migration code #{inspect(other)}: #{other |> Macro.to_string() |> Code.format_string!()}"
    )

    []
  end

  defp table_name(n) when is_binary(n), do: String.to_atom(n)
  defp table_name(n) when is_atom(n), do: n

  defp column_type_from_migration_type(:utc_datetime), do: :datetime
  defp column_type_from_migration_type(other), do: other

  defp migration_type_from_column_type(:datetime), do: :utc_datetime
  defp migration_type_from_column_type(other), do: other

  defp table_change(table, action, opts, columns) do
    columns =
      columns
      |> Enum.map(&column_change(&1))
      |> Enum.reject(fn col -> col[:column] == nil end)
      |> Enum.reduce(%{}, fn col, map ->
        type = column_type_from_migration_type(col[:type])

        Map.put(map, col[:column], %{
          type: type,
          opts: col[:opts],
          action: col[:action]
        })
      end)

    table = table_name(table)

    %{table: table, action: action, kind: :table, opts: opts, columns: columns}
  end

  defp column_change({:timestamps, _, _}) do
    %{meta: :timestamps, action: :create}
  end

  defp column_change({action, _, [name, type]}) do
    column_change({action, nil, [name, type, []]})
  end

  defp column_change({action, _, [name, type, opts]}) do
    type_change(%{column: name, opts: opts, action: action, kind: :column}, type)
  end

  defp column_change({action, _, [name]}) do
    %{column: name, action: action, kind: :column}
  end

  defp type_change(col, {:references, _, [table, [type: type]]}) do
    col
    |> put_in([:opts, :references], table)
    |> Map.put(:type, type)
  end

  defp type_change(col, type) when is_atom(type) do
    type = column_type_from_migration_type(type)

    Map.put(col, :type, type)
  end

  defp index_change(table, action, columns, opts) do
    %{index: opts[:name], action: action, kind: :index, table: table, columns: columns}
  end

  defp enum_change(enum, action, values) do
    %{enum: enum, action: action, kind: :enum, values: values}
  end

  defp parse_enum_expression(expr) do
    [enum | values] =
      expr
      |> String.replace("as ENUM (", "")
      |> String.replace(")", "")
      |> String.replace("'", "")
      |> String.replace(",", " ")
      |> String.split(" ")

    {String.to_atom(enum), Enum.map(values, &String.to_atom(&1))}
  end

  defp parse_enum_add_value_expression(expr) do
    [enum, _, value] =
      expr
      |> String.replace("add value", "")
      |> String.replace("'", "")
      |> String.split(" ")

    {String.to_atom(enum), String.to_atom(value)}
  end

  defp write_migration([], _, opts) do
    if Keyword.get(opts, :write_to_disk, true) do
      IO.puts("No migrations to write")
      :ok
    else
      []
    end
  end

  defp write_migration(migration, version, opts) do
    module_name = [:Graphism, :Migration, String.to_atom("V#{version}")]

    up =
      migration
      |> sort_migrations()
      |> Enum.map(&quote_migration(&1))
      |> List.flatten()

    code =
      module_name
      |> migration_module(up)
      |> Macro.to_string()
      |> Code.format_string!()

    {:ok, timestamp} =
      Calendar.DateTime.now_utc()
      |> Calendar.Strftime.strftime("%Y%m%d%H%M%S")

    path =
      Path.join([
        opts[:dir],
        "#{timestamp}_graphism_v#{version}.exs"
      ])

    code = code ++ ["\n"]

    if Keyword.get(opts, :write_to_disk, true) do
      File.mkdir_p!(opts[:dir])
      File.write!(path, code)
      IO.puts("Written #{path}")
    else
      [path: path, code: IO.iodata_to_binary(code)]
    end
  end

  defp table_references(m) do
    m[:columns]
    |> Enum.map(fn col ->
      col[:opts][:references]
    end)
    |> Enum.reject(fn table -> table == nil end)
  end

  defp tables_graph(migrations) do
    tables =
      migrations
      |> Enum.filter(fn m -> m[:kind] == :table and m[:action] == :create end)

    graph =
      Enum.reduce(tables, Graph.new(), fn m, g ->
        Graph.add_vertex(g, m[:table])
      end)

    Enum.reduce(tables, graph, fn m, g ->
      m
      |> table_references()
      |> Enum.reduce(g, fn parent, g ->
        Graph.add_edge(g, m[:table], parent)
      end)
    end)
  end

  defp table_index(tables, tab, inverse \\ false) do
    tables =
      case inverse do
        false ->
          tables

        true ->
          Enum.reverse(tables)
      end

    case Enum.find(tables, fn {t, _} -> tab == t end) do
      nil ->
        -1000

      {^tab, index} ->
        index
    end
  end

  # Sort migrations so that:
  #
  # * enums (types) are defined first
  # * then tables, with top level tables first
  # * then indices
  defp sort_migrations(migrations) do
    tables =
      migrations
      |> tables_graph()
      |> Graph.topsort()
      |> Enum.with_index()

    migrations
    |> Enum.map(fn m ->
      case m[:kind] do
        :table ->
          case m[:action] do
            :create ->
              {m, table_index(tables, m[:table])}

            :drop ->
              {m, table_index(tables, m[:table], true)}

            :alter ->
              {m, 0}
          end

        :enum ->
          {m, 1000}

        :index ->
          {m, -1000}

        _ ->
          raise "error: unknown kind in #{inspect(m)}. Expecting one of: [:table, :enum, :index]. This is a bug!"
      end
    end)
    |> Enum.sort(fn
      {_, ref1}, {_, ref2} ->
        ref1 > ref2
    end)
    |> Enum.map(fn {m, _} ->
      m
    end)
  end

  defp migration_module(name, up) do
    {:defmodule, [line: 1],
     [
       {:__aliases__, [line: 1], name},
       [
         do:
           {:__block__, [],
            [
              {:use, [line: 1], [{:__aliases__, [line: 1], [:Ecto, :Migration]}]},
              {:def, [line: 1],
               [
                 {:up, [line: 1], nil},
                 [
                   do: {:__block__, [], up}
                 ]
               ]},
              {:def, [line: 1],
               [
                 {:down, [line: 1], nil},
                 [do: []]
               ]}
            ]}
       ]
     ]}
  end

  defp quote_migration(%{table: table, action: :create, kind: :table, columns: cols}) do
    {:create, [line: 1],
     [
       {:table, [line: 1], [table, [primary_key: false]]},
       [
         do: {:__block__, [], Enum.map(cols, &column_change_ast(&1)) ++ [timestamps_ast()]}
       ]
     ]}
  end

  defp quote_migration(%{table: table, action: :alter, kind: :table, columns: cols}) do
    alter_table =
      {:alter, [line: 1],
       [
         {:table, [line: 1], [table]},
         [
           do: {:__block__, [], Enum.map(cols, &column_change_ast(&1))}
         ]
       ]}

    case Enum.filter(cols, &(&1[:action] == :modify and &1[:cast])) do
      [] ->
        alter_table

      cols ->
        Enum.map(cols, &column_alias_ast(table, &1)) ++ [alter_table]
    end
  end

  defp quote_migration(%{table: table, action: :drop, kind: :table}) do
    {:drop_if_exists, [line: 1],
     [
       {:table, [line: 1], [table]}
     ]}
  end

  defp quote_migration(%{
         index: index,
         action: :create,
         kind: :index,
         table: table,
         columns: columns
       }) do
    {:create, [line: 1],
     [
       {:unique_index, [line: 1], [table, columns, [name: index]]}
     ]}
  end

  defp quote_migration(%{
         index: index,
         action: :drop,
         kind: :index,
         table: table,
         columns: columns
       }) do
    {:drop_if_exists, [line: 1],
     [
       {:index, [line: 1], [table, columns, [name: index]]}
     ]}
  end

  defp quote_migration(%{enum: name, action: :create, kind: :enum, values: values}) do
    {:execute, [line: 1],
     [
       "create type #{name} as ENUM (#{
         values
         |> Enum.map(fn value -> "'#{value}'" end)
         |> Enum.join(",")
       })"
     ]}
  end

  defp quote_migration(%{enum: name, action: :alter, kind: :enum, value: value}) do
    {:execute, [line: 1],
     [
       "alter type #{name} add value '#{value}'"
     ]}
  end

  defp quote_migration(%{enum: name, action: :drop, kind: :enum, values: _}) do
    {:execute, [line: 1],
     [
       "drop type #{name}"
     ]}
  end

  defp column_alias_ast(table, col) do
    {:execute, [line: 1],
     [
       "alter table #{table} alter #{col[:column]} type #{col[:type]} using #{col[:column]}::#{col[:type]}"
     ]}
  end

  defp column_change_ast(%{column: name, type: type, opts: opts, action: action, kind: :column})
       when action in [:add, :modify] do
    type = migration_type_from_column_type(type)

    case opts do
      [] ->
        {action, [], [name, type]}

      _ ->
        # Transform :references hints into proper migration DSL
        case opts[:references] do
          nil ->
            {action, [], [name, type, opts]}

          target_table ->
            nullable = opts[:null] || false

            {action, [], [name, {:references, [], [target_table, [type: :uuid]]}, [null: nullable]]}
        end
    end
  end

  # Translates a drop table change into the AST
  # that will be included in a migration, inside an alter
  # table block
  defp column_change_ast(%{column: name, action: :remove, kind: :column}) do
    {:remove, [], [name]}
  end

  defp timestamps_ast() do
    {:timestamps, [line: 1], []}
  end
end
