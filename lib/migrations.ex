defmodule Graphism.Migrations do
  @moduledoc """
  A database migrations generator based on a
  Graphism schema
  """
  require Logger

  @migrations_dir Path.join([File.cwd!(), "priv/repo/migrations"])
  @migrations Path.join([@migrations_dir, "*_graphism_*.exs"])

  @doc """
  Generate migrations for the given schema.

  """
  def generate(module: mod) do
    schema = mod.schema()

    migrations = existing_migrations()

    existing_migrations =
      read_migrations(migrations)
      |> reduce_migrations()

    last_migration_version = last_migration_version(migrations)

    schema_migration = migration_from_schema(schema)

    missing_migrations =
      missing_migrations(
        existing_migrations,
        schema_migration
      )

    write_migration(missing_migrations, last_migration_version + 1, dir: File.cwd!())
  end

  defp migration_from_schema(schema) do
    # Index all entities, so that we can figure out foreign keys
    # using plurals and table names from referenced entities
    index =
      Enum.reduce(schema, %{}, fn e, acc ->
        Map.put(acc, e[:name], e)
      end)

    Enum.reduce(index, %{}, fn {_, entity}, acc ->
      migration_from_entity(entity, index, acc)
    end)
  end

  defp migration_from_entity(e, index, acc) do
    # convert entity attributes as simple columns
    # to be added to the table migrations
    m =
      Enum.reduce(e[:attributes], %{}, fn attr, m ->
        name = column_name_from_attribute(attr)
        type = column_type_from_attribute(attr, e)
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
      |> Enum.filter(fn rel -> :has_one == rel[:kind] or :belongs_to == rel[:kind] end)
      |> Enum.reduce(m, fn rel, m ->
        name = column_name_from_relation(rel)
        opts = column_opts_from_relation(rel, index)

        Map.put(m, name, %{
          type: :uuid,
          opts: opts
        })
      end)

    # Inspect attributes and derive unique indices
    indices =
      e[:attributes]
      |> Enum.filter(fn attr -> attr[:opts][:unique] end)
      |> Enum.reduce(%{}, fn attr, acc ->
        index = index_from_attribute(attr, e)
        Map.put(acc, index[:name], index)
      end)

    # Inspect attributes and derive enums
    enums =
      e[:attributes]
      |> Enum.filter(fn attr -> attr[:opts][:one_of] end)
      |> Enum.reduce(%{}, fn attr, acc ->
        enum = enum_from_attribute(attr, e)
        Map.put(acc, enum[:enum], enum)
      end)

    Map.put(acc, e[:table], %{
      columns: m,
      indices: indices,
      enums: enums
    })
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

  defp column_name_from_relation(rel) do
    String.to_atom("#{rel[:name]}_id")
  end

  defp column_opts_from_relation(rel, index) do
    target = entity!(index, rel[:target])
    referenced_tabled = target[:table]
    [null: false, references: referenced_tabled]
  end

  defp column_opts_from_attribute(attr) do
    []
    |> column_opts_with_primary_key(attr)
    |> column_opts_with_null(attr)
    |> column_opts_with_default(attr)
  end

  defp column_opts_with_primary_key(opts, attr) do
    case attr[:name] do
      :id ->
        Keyword.put(opts, :primary_key, true)

      _ ->
        opts
    end
  end

  defp column_opts_with_null(opts, attr) do
    case attr[:opts][:optional] do
      nil ->
        Keyword.put(opts, :null, false)

      _ ->
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

  defp column_type_from_attribute(attr, e) do
    kind = attr[:kind]

    unless kind do
      raise "entity attribute #{inspect(attr)} has no kind"
    end

    cond do
      :id == kind ->
        :uuid

      nil != attr[:opts][:one_of] ->
        enum_name(e, attr)

      true ->
        kind
    end
  end

  defp column_name_from_attribute(attr) do
    attr[:name]
  end

  defp index_from_attribute(attr, e) do
    column_name = column_name_from_attribute(attr)
    index_name = String.to_atom("unique_#{column_name}_per_#{e[:table]}")
    [table: e[:table], name: index_name, columns: [column_name]]
  end

  defp enum_name(e, attr) do
    String.to_atom("#{e[:table]}_#{attr[:name]}")
  end

  defp enum_from_attribute(attr, e) do
    [enum: enum_name(e, attr), table: e[:table], values: attr[:opts][:one_of]]
  end

  defp missing_migrations(existing, schema) do
    # New tables to be created
    tables_to_create = Map.keys(schema) -- Map.keys(existing)

    missing_migrations =
      Enum.reduce(tables_to_create, [], fn name, acc ->
        [create_table_migration(name, schema)] ++
          create_indices_migrations(name, schema) ++
          create_enums_migration(name, schema) ++
          acc
      end)

    # Old tables to be dropped
    tables_to_drop = Map.keys(existing) -- Map.keys(schema)

    missing_migrations =
      Enum.reduce(tables_to_drop, missing_migrations, fn name, acc ->
        [drop_table_migration(name) | acc]
      end)

    # Add the tables to be merged. We need to
    # implement the same logic at the column level, for each table
    tables_to_merge = Map.keys(schema) -- Map.keys(schema) -- Map.keys(existing)

    Enum.reduce(tables_to_merge, missing_migrations, fn name, acc ->
      existing_columns = Map.keys(existing[name][:columns])
      schema_columns = Map.keys(schema[name][:columns])

      # columns to add
      columns_to_add =
        (schema_columns -- existing_columns)
        |> Enum.map(fn col ->
          column = schema[name][:columns][col]
          [column: col, type: column[:type], opts: column[:opts], action: :add, kind: :column]
        end)

      # columns to remove
      columns_to_remove = existing_columns -- schema_columns

      case length(columns_to_add) + length(columns_to_remove) do
        0 ->
          # If we dont have anything to do, then we skip the
          # alter table migration altogether
          acc

        _ ->
          [alter_table_migration(name, columns_to_add, columns_to_remove) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp create_table_migration(name, schema) do
    [
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
    ]
  end

  # Add migrations for new indices to be created for the given table
  defp create_indices_migrations(name, schema) do
    Enum.reduce(schema[name][:indices], [], fn {_, index}, acc ->
      [create_index_migration(index) | acc]
    end)
  end

  defp create_index_migration(index) do
    index_migration(index, :create)
  end

  defp index_migration(index, action) do
    [
      index: index[:name],
      action: action,
      kind: :index,
      table: index[:table],
      columns: index[:columns]
    ]
  end

  defp drop_table_migration(name) do
    [
      table: name,
      action: :drop,
      kind: :table
    ]
  end

  defp create_enums_migration(name, schema) do
    Enum.reduce(schema[name][:enums], [], fn {_, e}, acc ->
      enum = [enum: e[:enum], action: :create, kind: :enum, table: name, values: e[:values]]

      [enum | acc]
    end)
  end

  defp alter_table_migration(name, columns_to_add, columns_to_remove) do
    [
      table: name,
      action: :alter,
      kind: :table,
      columns:
        Enum.map(columns_to_add, fn col ->
          [column: col[:column], type: col[:type], opts: col[:opts], action: :add, kind: :column]
        end) ++
          Enum.map(columns_to_remove, fn col ->
            [column: col, action: :remove, kind: :column]
          end)
    ]
  end

  defp migration_from_column(col, spec, action) do
    [column: col, type: spec[:type], opts: spec[:opts], action: action, kind: :column]
  end

  defp existing_migrations() do
    @migrations
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!(&1))
    |> Enum.map(&Code.string_to_quoted!(&1))
  end

  defp read_migrations(migrations) do
    migrations
    |> Enum.flat_map(&parse_migration(&1))
  end

  defp reduce_migrations(migrations) do
    migrations
    |> Enum.reduce(%{}, &reduce_migration(&1, &2))
  end

  defp reduce_migration(
         [table: t, action: :drop_if_exists, kind: :table, opts: _, columns: _],
         acc
       ) do
    Map.drop(acc, [t])
  end

  defp reduce_migration([table: t, action: :create, kind: :table, opts: _, columns: cols], acc) do
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
         [index: name, action: :create, kind: :index, table: table, columns: columns],
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
         [index: name, action: :drop_if_exists, kind: :index, table: table, columns: _],
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
         [table: t, action: :alter, kind: :table, opts: _, columns: column_changes] = spec,
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
        end
      end)

    # Then replace the resulting table columns
    # in our accumulator
    put_in(acc, [t, :columns], new_columns)
  end

  defp reduce_migration([enum: enum, action: :create, kind: :enum, table: t, values: values], acc) do
    table =
      case Map.get(acc, t) do
        nil ->
          # Usually we create enums before we create the tables where
          # they are used so it is expected that the table might not
          # be there yet
          %{columns: %{}, indices: [], enums: %{}}

        table ->
          table
      end

    enums =
      table
      |> Map.get(:enums)
      |> Map.put(enum, %{
        enum: enum,
        values: values
      })

    table = Map.put(table, :enums, enums)
    Map.put(acc, t, table)
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
    {enum, table, values} = parse_enum_expression(enum_expr)
    enum_change(enum, :create, table, values)
  end

  defp parse_up(other) do
    Logger.warn(
      "Unable to parse migration code #{inspect(other)}: #{
        other |> Macro.to_string() |> Code.format_string!()
      }"
    )

    []
  end

  defp table_name(n) when is_binary(n), do: String.to_atom(n)
  defp table_name(n) when is_atom(n), do: n

  defp table_change(table, action, opts, columns) do
    columns =
      columns
      |> Enum.map(&column_change(&1))
      |> Enum.reject(fn col -> col[:column] == nil end)
      |> Enum.reduce(%{}, fn col, map ->
        Map.put(map, col[:column], %{
          type: col[:type],
          opts: col[:opts],
          action: col[:action]
        })
      end)

    table = table_name(table)

    [table: table, action: action, kind: :table, opts: opts, columns: columns]
  end

  defp column_change({:timestamps, _, _}) do
    [meta: :timestamps, action: :create]
  end

  defp column_change({action, _, [name, type]}) do
    [column: name, type: type, opts: [], action: action, kind: :column]
  end

  defp column_change({action, _, [name, type, opts]}) do
    [column: name, type: type, opts: opts, action: action, kind: :column]
  end

  defp column_change({action, _, [name]}) do
    [column: name, action: action, kind: :column]
  end

  defp index_change(table, action, columns, opts) do
    [index: opts[:name], action: action, kind: :index, table: table, columns: columns]
  end

  defp enum_change(enum, action, table, values) do
    [enum: enum, action: action, kind: :enum, table: table, values: values]
  end

  defp parse_enum_expression(expr) do
    [enum | values] =
      expr
      |> String.replace("as ENUM (", "")
      |> String.replace(")", "")
      |> String.replace("'", "")
      |> String.replace(",", " ")
      |> String.split(" ")

    [table, _] = String.split(enum, "_")
    table = String.to_atom(table)

    {String.to_atom(enum), table, Enum.map(values, &String.to_atom(&1))}
  end

  defp write_migration([], _, _) do
    IO.puts("No migrations to write")
  end

  defp write_migration(migration, version, opts) do
    module_name = [:Graphism, :Migration, String.to_atom("V#{version}")]

    up =
      migration
      |> Enum.sort(&sort_migration(&1, &2))
      |> Enum.map(&quote_migration(&1))

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
        "priv",
        "repo",
        "migrations",
        "#{timestamp}_graphism_v#{version}.exs"
      ])

    File.write!(path, code)
    IO.puts("Written #{path}")
  end

  # Sort migrations depending on whether one references another
  # so that we apply top level migration first (ie a table that does not
  # depend on other tables) and dependent tables after
  defp sort_migration(m1, m2) do
    not depends(m1, m2)
  end

  # Figure out whether child migration depends on parent
  defp depends(child, parent) do
    case child[:kind] do
      :table ->
        # we are dealing with a table
        # See if there is a foreign reference to the parent
        not (child[:columns]
             |> Enum.filter(fn col ->
               col[:opts][:references] == parent[:table]
             end)
             |> Enum.empty?())

      :index ->
        # We are dealing with an index
        child[:table] == parent[:table]

      :enum ->
        false
    end
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

  defp quote_migration(table: table, action: :create, kind: :table, columns: cols) do
    {:create, [line: 1],
     [
       {:table, [line: 1], [table, [primary_key: false]]},
       [
         do: {:__block__, [], Enum.map(cols, &column_change_ast(&1)) ++ [timestamps_ast()]}
       ]
     ]}
  end

  defp quote_migration(table: table, action: :alter, kind: :table, columns: cols) do
    {:alter, [line: 1],
     [
       {:table, [line: 1], [table]},
       [
         do: {:__block__, [], Enum.map(cols, &column_change_ast(&1))}
       ]
     ]}
  end

  defp quote_migration(table: table, action: :drop, kind: :table) do
    {:drop_if_exists, [line: 1],
     [
       {:table, [line: 1], [table]}
     ]}
  end

  defp quote_migration(
         index: index,
         action: :create,
         kind: :index,
         table: table,
         columns: columns
       ) do
    {:create, [line: 1],
     [
       {:unique_index, [line: 1], [table, columns, [name: index]]}
     ]}
  end

  defp quote_migration(index: index, action: :drop, kind: :index, table: table, columns: columns) do
    {:drop_if_exists, [line: 1],
     [
       {:index, [line: 1], [table, columns, [name: index]]}
     ]}
  end

  defp quote_migration(enum: name, action: :create, kind: :enum, table: _, values: values) do
    {:execute, [line: 1],
     [
       "create type #{name} as ENUM (#{
         values
         |> Enum.map(fn value -> "'#{value}'" end)
         |> Enum.join(",")
       })"
     ]}
  end

  # Given a column change, generate the AST that will be
  # included in a migration, inside a create/alter table block
  defp column_change_ast(column: name, type: type, opts: opts, action: :add, kind: :column) do
    case opts do
      [] ->
        {:add, [], [name, type]}

      _ ->
        # Transform :references hints into proper migration DSL
        case opts[:references] do
          nil ->
            {:add, [], [name, type, opts]}

          target_table ->
            {:add, [], [name, {:references, [], [target_table, [type: :uuid]]}, [null: false]]}
        end
    end
  end

  # Translates a drop table change into the AST
  # that will be included in a migration, inside an alter
  # table block
  defp column_change_ast(column: name, action: :remove, kind: :column) do
    {:remove, [], [name]}
  end

  defp timestamps_ast() do
    {:timestamps, [line: 1], []}
  end
end
