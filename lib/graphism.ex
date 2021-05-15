defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  require Logger

  defmacro __using__(opts \\ []) do
    Code.compiler_options(ignore_module_conflict: true)

    alias Dataloader, as: DL

    repo = opts[:repo]

    unless repo do
      raise "Please specify a repo module when using Graphism"
    end

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :repo,
      accumulate: false,
      persist: true
    )

    Module.put_attribute(__CALLER__.module, :repo, opts[:repo])

    quote do
      defmodule Dataloader.Repo do
        def data() do
          DL.Ecto.new(unquote(repo), query: &query/2)
        end

        def query(queryable, _params) do
          queryable
        end
      end

      import unquote(__MODULE__), only: :macros
      @before_compile unquote(__MODULE__)
      use Absinthe.Schema
      import Absinthe.Resolution.Helpers, only: [dataloader: 1]

      @sources [unquote(__CALLER__.module).Dataloader.Repo]

      def context(ctx) do
        loader =
          Enum.reduce(@sources, DL.new(), fn source, loader ->
            DL.add_source(loader, source, source.data())
          end)

        Map.put(ctx, :loader, loader)
      end

      def plugins do
        [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
      end

      def middleware(middleware, _field, %{identifier: :mutation}) do
        middleware ++ [Graphism.ErrorMiddleware]
      end

      def middleware(middleware, _field, _object), do: middleware
    end
  end

  defmacro __before_compile__(_) do
    schema =
      __CALLER__.module
      |> Module.get_attribute(:schema)
      |> resolve()

    repo =
      __CALLER__.module
      |> Module.get_attribute(:repo)

    unless length(schema) > 0 do
      raise """
        Your Graphism schema is empty. Please define at least
        one entity:

        entity :my_entity do
          attribute :id, :id
          attribute :name, :string
        end 
      """
    end

    schema_fun =
      quote do
        def schema do
          unquote(schema)
        end
      end

    schema =
      schema
      |> Enum.reverse()

    schema
    |> Enum.each(fn e ->
      if Enum.empty?(e[:attributes]) and
           Enum.empty?(e[:relations]) do
        raise "Entity #{e[:name]} is empty"
      end
    end)


    schema_empty_modules =
      schema
      |> Enum.map(fn e ->
        schema_empty_module(e, schema, caller: __CALLER__)
      end)

    schema_modules =
      schema
      |> Enum.map(fn e ->
        schema_module(e, schema, caller: __CALLER__)
      end)

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, repo: repo, caller: __CALLER__)
      end)

    resolver_modules =
      Enum.map(schema, fn e ->
        resolver_module(e, schema, caller: __CALLER__)
      end)

    enums =
      Enum.map(schema, fn e ->
        graphql_enum(e, schema)
      end)

    objects =
      Enum.map(schema, fn e ->
        graphql_object(e, schema, caller: __CALLER__.module)
      end)

    queries =
      quote do
        query do
          (unquote_splicing(
             Enum.flat_map(schema, fn e ->
               graphql_queries(e, schema)
             end)
           ))
        end
      end

    mutations =
      quote do
        mutation do
          (unquote_splicing(
             Enum.flat_map(schema, fn e ->
               graphql_mutations(e, schema)
             end)
           ))
        end
      end

    List.flatten([
      schema_fun,
      schema_empty_modules,
      schema_modules,
      api_modules,
      resolver_modules,
      enums,
      objects,
      queries,
      mutations
    ])
  end

  defmacro entity(name, _attrs \\ [], do: block) do
    caller_module = __CALLER__.module

    attrs = attributes_from(block)
    rels = relations_from(block)

    entity =
      [name: name, attributes: attrs, relations: rels, enums: []]
      |> with_plural()
      |> with_table_name()
      |> with_schema_module(caller_module)
      |> with_api_module(caller_module)
      |> with_resolver_module(caller_module)
      |> with_enums()

    Module.put_attribute(__CALLER__.module, :schema, entity)

    block
  end

  defmacro attribute(name, type, opts \\ []) do
    validate_attribute_name!(name)
    validate_attribute_type!(type)
    validate_attribute_opts!(opts)
  end

  defmacro has_many(_name, _opts \\ []) do
  end

  defmacro has_one(_name, _opts \\ []) do
  end

  defmacro belongs_to(_name, _opts \\ []) do
  end

  defp validate_attribute_name!(name) do
    unless is_atom(name) do
      raise "Attribute #{name} should be an atom"
    end
  end

  @supported_attribute_types [
    :id,
    :string,
    :integer,
    :number,
    :date,
    :boolean
  ]

  defp validate_attribute_type!(type) do
    unless Enum.member?(@supported_attribute_types, type) do
      raise "Unsupported attribute type #{inspect(type)}. Must be one of #{
              inspect(@supported_attribute_types)
            }"
    end
  end

  defp validate_attribute_opts!(opts) do
    unless is_list(opts) do
      raise "Unsupported attribute opts #{inspect(opts)}. Must be a keyword list"
    end
  end

  defp with_plural(entity) do
    case entity[:plural] do
      nil ->
        Keyword.put(entity, :plural, String.to_atom("#{entity[:name]}s"))

      _ ->
        entity
    end
  end

  defp with_table_name(entity) do
    table_name =
      entity[:plural]
      |> Atom.to_string()
      |> Inflex.parameterize("_")
      |> String.to_atom()

    Keyword.put(entity, :table, table_name)
  end

  defp with_schema_module(entity, caller_mod) do
    module_name(caller_mod, entity, :schema_module)
  end

  defp with_resolver_module(entity, caller_mod) do
    module_name(caller_mod, entity, :resolver_module, :resolver)
  end

  defp with_api_module(entity, caller_mod) do
    module_name(caller_mod, entity, :api_module, :api)
  end

  defp module_name(prefix, entity, name, suffix \\ nil) do
    module_name =
      [prefix, entity[:name], suffix]
      |> Enum.reject(fn part -> part == nil end)
      |> Enum.map(&Atom.to_string(&1))
      |> Enum.map(&Inflex.camelize(&1))
      |> Module.concat()

    Keyword.put(
      entity,
      name,
      module_name
    )
  end

  # Inspect attributes and extract enum types from those attributes
  # that have a defined set of possible values
  defp with_enums(entity) do
    enums =
      entity[:attributes]
      |> Enum.filter(fn attr -> attr[:opts][:one_of] end)
      |> Enum.reduce([], fn attr, enums ->
        enum_name = enum_name(entity, attr)
        values = attr[:opts][:one_of]
        [[name: enum_name, values: values] | enums]
      end)

    Keyword.put(entity, :enums, enums)
  end

  defp enum_name(e, attr) do
    String.to_atom("#{e[:name]}_#{attr[:name]}s")
  end

  # Resolves the given schema, by inspecting links between entities
  # and making sure everything is consistent
  defp resolve(schema) do
    # Index plurals so that we can later resolve relations
    plurals =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:plural], e[:name])
      end)

    # Index entities by name
    index =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:name], e)
      end)

    schema
    |> Enum.map(fn e ->
      e
      |> with_display_name()
      |> with_relations!(index, plurals)
    end)
  end

  def with_display_name(e) do
    display_name = display_name(e[:name])

    plural_display_name = display_name(e[:plural])

    e
    |> Keyword.put(:display_name, display_name)
    |> Keyword.put(:plural_display_name, plural_display_name)
  end

  defp display_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> Inflex.camelize()
    |> :string.titlecase()
  end

  # Ensure all relations are properly formed. 
  # This function will raise an error if the target entity
  # for a relation cannot be found
  defp with_relations!(e, index, plurals) do
    relations =
      e[:relations]
      |> Enum.map(fn rel ->
        case rel[:kind] do
          :has_many ->
            target = plurals[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(plurals)
                    }"
            end

            rel
            |> Keyword.put(:target, target)
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

          _ ->
            target = index[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(Map.keys(index))
                    }"
            end

            rel
            |> Keyword.put(:target, target[:name])
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])
        end
      end)

    Keyword.put(e, :relations, relations)
  end

  defp schema_empty_module(e, _schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
      end
    end
  end

  defp schema_module(e, schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
        use Ecto.Schema
        import Ecto.Changeset

        unquote_splicing(
          # alias all modules referenced by has_many
          # relations

          e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
          |> Enum.map(fn rel ->
            target = find_entity!(schema, rel[:target])
            schema_module = target[:schema_module]

            quote do
              alias unquote(schema_module)
            end
          end)
        )

        @primary_key {:id, :binary_id, autogenerate: false}

        schema unquote("#{e[:plural]}") do
          unquote_splicing(
            e[:attributes]
            |> Enum.reject(fn attr -> attr[:name] == :id end)
            |> Enum.map(fn attr ->
              quote do
                Ecto.Schema.field(unquote(attr[:name]), unquote(attr[:kind]))
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              target = find_entity!(schema, rel[:target])

              quote do
                Ecto.Schema.belongs_to(unquote(rel[:name]), unquote(target[:schema_module]),
                  type: :binary_id
                )
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
            |> Enum.map(fn rel ->
              target = find_entity!(schema, rel[:target])
              schema_module = target[:schema_module]

              quote do
                Ecto.Schema.has_many(unquote(rel[:name]), unquote(schema_module))
              end
            end)
          )

          timestamps()
        end

        @required_fields unquote(
                           (e[:attributes]
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e[:relations]
                              |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        def changeset(e, attrs) do
          changes =
            e
            |> cast(attrs, @required_fields)
            |> validate_required(@required_fields)
            |> unique_constraint(:id, name: unquote("#{e[:table]}_pkey"))

          unquote_splicing(
            e[:attributes]
            |> Enum.filter(fn attr -> attr[:opts][:unique] end)
            |> Enum.map(fn attr ->
              quote do
                changes =
                  changes
                  |> unique_constraint(
                    unquote(attr[:name]),
                    name: unquote("unique_#{attr[:name]}_per_#{e[:table]}")
                  )
              end
            end)
          )
        end
      end
    end
  end

  defp resolver_module(e, schema, _) do
    api_module = e[:api_module]

    quote do
      defmodule unquote(e[:resolver_module]) do
        def list_all(_, _, _) do
          {:ok, unquote(api_module).list()}
        end

        def get_by_id(_, %{id: id}, _) do
          unquote(api_module).get_by_id(id)
        end

        unquote_splicing(
          e[:attributes]
          |> Enum.filter(fn attr -> attr[:opts][:unique] end)
          |> Enum.map(fn attr ->
            quote do
              def unquote(String.to_atom("get_by_#{attr[:name]}"))(
                    _,
                    %{unquote(attr[:name]) => arg},
                    _
                  ) do
                unquote(api_module).unquote(String.to_atom("get_by_#{attr[:name]}"))(arg)
              end
            end
          end)
        )

        unquote_splicing(
          e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
          |> Enum.map(fn rel ->
            quote do
              def unquote(String.to_atom("list_by_#{rel[:name]}"))(
                    _,
                    %{unquote(rel[:name]) => arg},
                    _
                  ) do
                {:ok, unquote(api_module).unquote(String.to_atom("list_by_#{rel[:name]}"))(arg)}
              end
            end
          end)
        )

        def create(_, args, _) do
          unquote(
            case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
              [] ->
                quote do
                  unquote(api_module).create(args)
                end

              rels ->
                quote do
                  with unquote_splicing(
                         rels
                         |> Enum.map(fn rel ->
                           parent_var = Macro.var(rel[:name], nil)
                           target = find_entity!(schema, rel[:target])

                           quote do
                             {:ok, unquote(parent_var)} <-
                               unquote(target[:api_module]).get_by_id(args.unquote(rel[:name]))
                           end
                         end)
                       ) do
                    args = Map.drop(args, unquote(Enum.map(rels, fn rel -> rel[:name] end)))

                    unquote(api_module).create(
                      unquote_splicing(
                        Enum.map(rels, fn rel ->
                          Macro.var(rel[:name], nil)
                        end)
                      ),
                      args
                    )
                  end
                end
            end
          )
        end

        def update(_, %{id: id} = args, _) do
          with {:ok, entity} <- unquote(api_module).get_by_id(id) do
            args = Map.drop(args, [:id])

            unquote(
              case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
                [] ->
                  quote do
                    unquote(api_module).update(entity, args)
                  end

                rels ->
                  quote do
                    with unquote_splicing(
                           rels
                           |> Enum.map(fn rel ->
                             parent_var = Macro.var(rel[:name], nil)
                             target = find_entity!(schema, rel[:target])

                             quote do
                               {:ok, unquote(parent_var)} <-
                                 unquote(target[:api_module]).get_by_id(args.unquote(rel[:name]))
                             end
                           end)
                         ) do
                      args = Map.drop(args, unquote(Enum.map(rels, fn rel -> rel[:name] end)))

                      unquote(api_module).update(
                        unquote_splicing(
                          Enum.map(rels, fn rel ->
                            Macro.var(rel[:name], nil)
                          end)
                        ),
                        entity,
                        args
                      )
                    end
                  end
              end
            )
          end
        end

        def delete(_, %{id: id}, _) do
          with {:ok, entity} <- unquote(api_module).get_by_id(id) do
            unquote(api_module).delete(entity)
          end
        end
      end
    end
  end

  defp api_module(e, _, opts) do
    schema_module = e[:schema_module]
    repo_module = opts[:repo]

    quote do
      defmodule unquote(e[:api_module]) do
        import Ecto.Query, only: [from: 2]

        def list do
          unquote(schema_module)
          |> unquote(repo_module).all()
        end

        def get_by_id(id) do
          case unquote(schema_module)
               |> unquote(repo_module).get(id) do
            nil ->
              {:error, :not_found}

            e ->
              {:ok, e}
          end
        end

        unquote_splicing(
          e[:attributes]
          |> Enum.filter(fn attr -> attr[:opts][:unique] end)
          |> Enum.map(fn attr ->
            quote do
              def unquote(String.to_atom("get_by_#{attr[:name]}"))(value) do
                value =
                  case is_atom(value) do
                    true ->
                      "#{value}"

                    false ->
                      value
                  end

                case unquote(schema_module)
                     |> unquote(repo_module).get_by([{unquote(attr[:name]), value}]) do
                  nil ->
                    {:error, :not_found}

                  e ->
                    {:ok, e}
                end
              end
            end
          end)
        )

        unquote_splicing(
          e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
          |> Enum.map(fn rel ->
            quote do
              def unquote(String.to_atom("list_by_#{rel[:name]}"))(id) do
                query =
                  from(unquote(Macro.var(rel[:name], nil)) in unquote(schema_module),
                    where:
                      unquote(Macro.var(rel[:name], nil)).unquote(
                        String.to_atom("#{rel[:name]}_id")
                      ) == ^id
                  )

                unquote(repo_module).all(query)
              end
            end
          end)
        )

        def create(
              unquote_splicing(
                e[:relations]
                |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                |> Enum.map(fn rel -> Macro.var(rel[:name], nil) end)
              ),
              attrs
            ) do
          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              quote do
                attrs =
                  attrs
                  |> Map.put(
                    unquote(String.to_atom("#{rel[:name]}_id")),
                    unquote(Macro.var(rel[:name], nil)).id
                  )
              end
            end)
          )

          with {:ok, e} <-
                 %unquote(schema_module){}
                 |> unquote(schema_module).changeset(attrs)
                 |> unquote(repo_module).insert() do
            get_by_id(e.id)
          end
        end

        def update(
              unquote_splicing(
                e[:relations]
                |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                |> Enum.map(fn rel ->
                  Macro.var(rel[:name], nil)
                end)
              ),
              unquote(Macro.var(e[:name], nil)),
              attrs
            ) do
          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              quote do
                attrs =
                  attrs
                  |> Map.put(
                    unquote(String.to_atom("#{rel[:name]}_id")),
                    unquote(Macro.var(rel[:name], nil)).id
                  )
              end
            end)
          )

          with {:ok, unquote(Macro.var(e[:name], nil))} <-
                 unquote(Macro.var(e[:name], nil))
                 |> unquote(schema_module).changeset(attrs)
                 |> unquote(repo_module).update() do
            get_by_id(unquote(Macro.var(e[:name], nil)).id)
          end
        end

        def delete(%unquote(schema_module){} = e) do
          unquote(repo_module).delete(e)
        end
      end
    end
  end

  defp find_entity!(schema, name) do
    case Enum.filter(schema, fn e ->
           name == e[:name]
         end) do
      [] ->
        raise "Could not resolve entity #{name}: #{
                inspect(Enum.map(schema, fn e -> e[:name] end))
              }"

      [e] ->
        e
    end
  end

  defp attr_graphql_type(e, attr) do
    case attr[:opts][:one_of] do
      nil ->
        # it is not an enum, so we use its defined type
        attr[:kind]

      [_ | _] ->
        # use the name of the enum as the type
        enum_name(e, attr)
    end
  end

  defp graphql_object(e, _schema, opts) do
    quote do
      object unquote(e[:name]) do
        (unquote_splicing(
           # Add a field for each attribute
           Enum.map(e[:attributes], fn attr ->
             # determine the kind for this field, depending
             # on whether it is an enum or not
             kind = attr_graphql_type(e, attr)

             quote do
               field(unquote(attr[:name]), unquote(kind))
             end
           end) ++
             Enum.map(e[:relations], fn rel ->
               # Add a field for each relation
               quote do
                 field(
                   unquote(rel[:name]),
                   unquote(
                     case rel[:kind] do
                       :has_many ->
                         quote do
                           list_of(unquote(rel[:target]))
                         end

                       _ ->
                         quote do
                           non_null(unquote(rel[:target]))
                         end
                     end
                   ),
                   resolve: dataloader(unquote(opts[:caller]).Dataloader.Repo)
                 )
               end
             end)
         ))
      end
    end
  end

  defp graphql_enum(e, _) do
    Enum.map(e[:enums], fn enum ->
      quote do
        enum unquote(enum[:name]) do
          (unquote_splicing(
             Enum.map(enum[:values], fn value ->
               quote do
                 value(unquote(value), as: unquote("#{value}"))
               end
             end)
           ))
        end
      end
    end)
  end

  defp graphql_queries(e, schema) do
    List.flatten([
      graphql_query_list_all(e, schema),
      graphql_query_find_by_id(e, schema),
      graphql_query_find_by_unique_fields(e, schema),
      graphql_query_find_by_parent_types(e, schema)
    ])
  end

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural_display_name]}")
      field unquote(e[:plural]), list_of(unquote(e[:name])) do
        resolve(&unquote(e[:resolver_module]).list_all/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field unquote(String.to_atom("#{e[:name]}_by_id")),
            unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).get_by_id/3)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(fn attr -> Keyword.get(attr[:opts], :unique) end)
    |> Enum.map(fn attr ->
      kind = attr_graphql_type(e, attr)

      quote do
        @desc "Find a single " <>
                unquote("#{e[:display_name]}") <>
                " given its unique " <> unquote("#{attr[:name]}")
        field unquote(String.to_atom("#{e[:name]}_by_#{attr[:name]}")),
              unquote(e[:name]) do
          arg(unquote(attr[:name]), non_null(unquote(kind)))

          resolve(
            &(unquote(e[:resolver_module]).unquote(String.to_atom("get_by_#{attr[:name]}")) / 3)
          )
        end
      end
    end)
  end

  defp graphql_query_find_by_parent_types(e, _schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
    |> Enum.map(fn rel ->
      quote do
        @desc "Find all " <>
                unquote("#{e[:plural_display_name]}") <>
                " given their parent " <> unquote("#{rel[:target]}")
        field unquote(String.to_atom("#{e[:plural]}_by_#{rel[:name]}")),
              list_of(unquote(e[:name])) do
          arg(unquote(rel[:name]), non_null(:id))

          resolve(
            &(unquote(e[:resolver_module]).unquote(String.to_atom("list_by_#{rel[:name]}")) / 3)
          )
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    [
      graphql_create_mutation(e, schema),
      graphql_update_mutation(e, schema),
      graphql_delete_mutation(e, schema)
    ]
  end

  defp graphql_create_mutation(e, _schema) do
    mutation_name = String.to_atom("create_#{e[:name]}")

    quote do
      @desc unquote("Create a new #{e[:display_name]}")
      field unquote(mutation_name), non_null(unquote(e[:name])) do
        unquote_splicing(
          Enum.map(e[:attributes], fn attr ->
            kind = attr_graphql_type(e, attr)

            quote do
              arg(unquote(attr[:name]), non_null(unquote(kind)))
            end
          end) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), non_null(:id))
               end
             end))
        )

        resolve(&unquote(e[:resolver_module]).create/3)
      end
    end
  end

  defp graphql_update_mutation(e, _schema) do
    mutation_name = String.to_atom("update_#{e[:name]}")

    quote do
      @desc unquote("Update an existing #{e[:display_name]}")
      field unquote(mutation_name), non_null(unquote(e[:name])) do
        unquote_splicing(
          Enum.map(e[:attributes], fn attr ->
            quote do
              arg(unquote(attr[:name]), non_null(unquote(attr[:kind])))
            end
          end) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), non_null(:id))
               end
             end))
        )

        resolve(&unquote(e[:resolver_module]).update/3)
      end
    end
  end

  defp graphql_delete_mutation(e, _schema) do
    mutation_name = String.to_atom("delete_#{e[:name]}")

    quote do
      @desc "Delete an existing " <> unquote("#{e[:display_name]}")
      field unquote(mutation_name), unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).delete/3)
      end
    end
  end

  defp attributes_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:attribute, _, attr} ->
        attribute(attr)

      _ ->
        nil
    end)
    |> Enum.reject(fn attr -> attr == nil end)
  end

  defp attributes_from({:attribute, _, attr}) do
    [attribute(attr)]
  end

  defp attributes_from(_) do
    []
  end

  defp attribute([name, kind]), do: [name: name, kind: kind, opts: []]
  defp attribute([name, kind, opts]), do: [name: name, kind: kind, opts: opts]

  defp relations_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:has_many, _, [name]} ->
        [name: name, kind: :has_many, opts: []]

      {:has_many, _, [name, opts]} ->
        [name: name, kind: :has_many, opts: opts]

      {:has_one, _, [name]} ->
        [name: name, kind: :has_one, opts: []]

      {:has_one, _, [name, opts]} ->
        [name: name, kind: :has_one, opts: opts]

      {:belongs_to, _, [name]} ->
        [name: name, kind: :belongs_to, opts: []]

      {:belongs_to, _, [name, opts]} ->
        [name: name, kind: :belongs_to, opts: opts]

      _ ->
        nil
    end)
    |> Enum.reject(fn rel -> rel == nil end)
  end

  defp relations_from(_) do
    []
  end
end
