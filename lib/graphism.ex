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

    alias Dataloader, as: DL

    quote do
      defmodule Dataloader.Repo do
        def data do
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
      @fields_auth unquote(__CALLER__.module).FieldsAuth

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

      def middleware(middleware, _field, object) do
        middleware ++ [Graphism.ErrorMiddleware, @fields_auth]
      end
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

    schema_settings =
      quote do
        defmodule FieldsAuth do
          alias Absinthe.Blueprint.Document.Field

          def call(
                %{
                  definition: %Field{
                    schema_node: %Absinthe.Type.Field{identifier: field},
                    parent_type: %Absinthe.Type.Object{identifier: entity}
                  }
                } = resolution,
                _
              ) do
            auth(entity, field, resolution)
          end

          def call(resolution, _), do: resolution

          unquote_splicing(
            Enum.flat_map(schema, fn e ->
              (e[:attributes] ++ e[:relations])
              |> Enum.filter(fn attr -> attr[:opts][:allow] end)
              |> Enum.map(fn field ->
                mod = field[:opts][:allow]

                quote do
                  defp auth(unquote(e[:name]), unquote(field[:name]), resolution) do
                    context =
                      resolution.context
                      |> Map.drop([:pubsub, :loader, :__absinthe_plug__])

                    case unquote(mod).allow?(resolution.value, context) do
                      true ->
                        resolution

                      false ->
                        %{resolution | value: nil}
                    end
                  end
                end
              end)
            end)
          )

          defp auth(_, _, resolution), do: resolution
        end
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
      |> Enum.reject(&virtual?(&1))
      |> Enum.map(fn e ->
        schema_empty_module(e, schema, caller: __CALLER__)
      end)

    schema_modules =
      schema
      |> Enum.reject(&virtual?(&1))
      |> Enum.map(fn e ->
        schema_module(e, schema, caller: __CALLER__)
      end)

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, repo: repo, caller: __CALLER__)
      end)

    resolver_modules =
      Enum.map(schema, fn e ->
        resolver_module(e, schema, repo: repo, caller: __CALLER__)
      end)

    enums =
      Enum.map(schema, fn e ->
        graphql_enum(e, schema)
      end)

    objects = [
      unit_graphql_object()
      | Enum.map(schema, fn e ->
          graphql_object(e, schema, caller: __CALLER__.module)
        end)
    ]

    self_resolver =
      quote do
        defmodule Resolver.Self do
          def itself(parent, _, _) do
            {:ok, parent}
          end
        end
      end

    entities_queries =
      Enum.flat_map(schema, fn e ->
        [single_graphql_queries(e, schema), multiple_graphql_queries(e, schema)]
      end)
      |> without_nils()

    queries =
      quote do
        query do
          (unquote_splicing(
             schema
             |> Enum.reject(&internal?(&1))
             |> Enum.flat_map(fn e ->
               [
                 with_entity_action(e, :read, fn _ ->
                   quote do
                     field unquote(String.to_atom("#{e[:plural]}")),
                           non_null(unquote(String.to_atom("#{e[:plural]}_queries"))) do
                       resolve(&Resolver.Self.itself/3)
                     end
                   end
                 end),
                 with_entity_action(e, :list, fn _ ->
                   quote do
                     field unquote(String.to_atom("#{e[:name]}")),
                           non_null(unquote(String.to_atom("#{e[:name]}_queries"))) do
                       resolve(&Resolver.Self.itself/3)
                     end
                   end
                 end)
               ]
             end)
             |> without_nils()
           ))
        end
      end

    input_types =
      schema
      |> Enum.reject(&internal?(&1))
      |> Enum.flat_map(fn e ->
        graphql_input_types(e, schema)
      end)
      |> without_nils()

    entities_mutations =
      schema
      |> Enum.reject(&internal?(&1))
      |> Enum.map(fn e ->
        graphql_mutations(e, schema)
      end)
      |> without_nils()

    mutations =
      quote do
        mutation do
          (unquote_splicing(
             schema
             |> Enum.reject(&internal?(&1))
             |> Enum.map(fn e ->
               case mutations?(e) do
                 true ->
                   quote do
                     field unquote(String.to_atom("#{e[:name]}")),
                           non_null(unquote(String.to_atom("#{e[:name]}_mutations"))) do
                       resolve(&Resolver.Self.itself/3)
                     end
                   end

                 false ->
                   nil
               end
             end)
             |> without_nils()
           ))
        end
      end

    List.flatten([
      schema_settings,
      schema_fun,
      schema_empty_modules,
      schema_modules,
      api_modules,
      resolver_modules,
      enums,
      input_types,
      objects,
      self_resolver,
      entities_queries,
      queries,
      entities_mutations,
      mutations
    ])
  end

  defmacro entity(name, opts \\ [], do: block) do
    caller_module = __CALLER__.module

    attrs = attributes_from(block)
    rels = relations_from(block)
    actions = actions_from(block)

    {actions, custom_actions} = split_actions(actions)

    entity =
      [
        name: name,
        attributes: attrs,
        relations: rels,
        enums: [],
        opts: opts,
        actions: actions,
        custom_actions: custom_actions
      ]
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

  defmacro action(_name, _opts) do
  end

  defp without_nils(enum) do
    Enum.reject(enum, fn item -> item == nil end)
  end

  defp flat(enum), do: List.flatten(enum)

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
      raise "Unsupported attribute type #{inspect(type)}. Must be one of #{inspect(@supported_attribute_types)}"
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
        plural = Inflex.pluralize("#{entity[:name]}")
        Keyword.put(entity, :plural, String.to_atom(plural))

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

  defp with_entity_action(e, action, next) do
    case action_for(e, action) do
      nil ->
        nil

      opts ->
        next.(opts)
    end
  end

  defp split_actions(all) do
    Enum.split_with(all, fn {name, _} ->
      built_in_action?(name)
    end)
  end

  @built_in_actions [:read, :list, :create, :update, :delete]

  defp built_in_action?(name) do
    Enum.member?(@built_in_actions, name)
  end

  defp virtual?(entity) do
    Enum.member?(entity[:opts][:modifiers] || [], :virtual)
  end

  defp internal?(entity) do
    Enum.member?(entity[:opts][:modifiers] || [], :internal)
  end

  defp private?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :private)
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
        rel =
          case rel[:kind] do
            :has_many ->
              target = plurals[rel[:plural]]

              unless target do
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(plurals))}. Relation: #{
                        inspect(rel)
                      }"
              end

              rel
              |> Keyword.put(:target, target)
              |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

            _ ->
              target = index[rel[:name]]

              unless target do
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(index))}"
              end

              rel
              |> Keyword.put(:target, target[:name])
              |> Keyword.put(:name, rel[:opts][:as] || rel[:name])
          end

        opts = rel[:opts]

        opts =
          opts
          |> with_action_hook(:allow)

        Keyword.put(rel, :opts, opts)
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
                Ecto.Schema.belongs_to(unquote(rel[:name]), unquote(target[:schema_module]), type: :binary_id)
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
                            |> Enum.reject(&optional?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e
                              |> parent_relations()
                              |> Enum.reject(&optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @optional_fields unquote(
                           (e[:attributes]
                            |> Enum.filter(&optional?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e[:relations]
                              |> Enum.filter(fn rel ->
                                rel[:kind] == :has_one || rel[:kind] == :belongs_to
                              end)
                              |> Enum.filter(&optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        def required_fields, do: @required_fields
        def optional_fields, do: @optional_fields

        def changeset(e, attrs) do
          changes =
            e
            |> cast(attrs, @required_fields)
            |> cast(attrs, @optional_fields)
            |> validate_required(@required_fields)
            |> unique_constraint(:id, name: unquote("#{e[:table]}_pkey"))

          unquote_splicing(
            e[:attributes]
            |> Enum.filter(&unique?(&1))
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

        def delete_changeset(e) do
          changes = e |> cast(%{}, [])

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :has_one || rel[:kind] == :has_many end)
            |> Enum.map(fn rel ->
              target = find_entity!(schema, rel[:target])
              target_table = target[:table]
              constraint = "#{target_table}_#{e[:name]}_id_fkey"
              message = "not empty"

              quote do
                changes =
                  changes
                  |> foreign_key_constraint(unquote(rel[:name]),
                    name: unquote(constraint),
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

  defp with_entity_funs(funs, e, action, fun) do
    case action?(e, action) do
      true ->
        case fun.() do
          [_ | _] = more_funs ->
            more_funs ++ [funs]

          single_fun ->
            [single_fun | funs]
        end

      false ->
        funs
    end
  end

  defp with_resolver_read_funs(funs, e, _schema, _api_module) do
    with_entity_funs(funs, e, :read, fn ->
      [
        quote do
          def get_by_id(_, %{id: id} = args, %{context: context}) do
            with unquote_splicing([
                   with_entity_fetch(e),
                   with_should(e, :read)
                 ]) do
              {:ok, unquote(var(e))}
            end
          end
        end
        | e[:attributes]
          |> Enum.filter(&unique?(&1))
          |> Enum.map(fn attr ->
            attr_name = attr[:name]
            fun_name = String.to_atom("get_by_#{attr[:name]}")

            quote do
              def unquote(fun_name)(
                    _,
                    %{unquote(attr_name) => arg} = args,
                    %{context: context}
                  ) do
                with unquote_splicing([with_entity_fetch(e, attr_name), with_should(e, :read)]) do
                  {:ok, unquote(var(e))}
                end
              end
            end
          end)
      ]
    end)
  end

  defp find_relation_by_kind_and_target!(e, kind, target) do
    rel =
      e[:relations]
      |> Enum.find(fn rel ->
        rel[:kind] == kind && rel[:target] == target
      end)

    unless rel do
      raise "relation of kind #{kind} and target #{target} not found in #{inspect(e)}"
    end

    rel
  end

  defp with_resolver_auth_funs(funs, e, schema) do
    funs ++
      ((e[:actions] ++ e[:custom_actions])
       |> Enum.map(fn {name, opts} ->
         resolver_auth_fun(name, opts, e, schema)
       end))
  end

  defp ancestor_auth_context(e, schema, context_var) do
    e
    |> parent_relations()
    |> Enum.flat_map(fn rel ->
      target = find_entity!(schema, rel[:target])
      parent_context_var = var(target)

      [
        quote do
          unquote(parent_context_var) = unquote(context_var).unquote(rel[:name])

          context =
            Map.put(
              context,
              unquote(target[:name]),
              unquote(parent_context_var)
            )
        end
        | ancestor_auth_context(target, schema, parent_context_var)
      ]
    end)
  end

  defp auth_fun_entities_args(e, action) do
    case action do
      :update ->
        (e |> parent_relations() |> vars()) ++ [var(e)]

      :delete ->
        [var(e)]

      :create ->
        e |> parent_relations() |> vars()

      :read ->
        [var(e)]

      _ ->
        []
    end
  end

  defp resolver_auth_fun(action, opts, e, schema) do
    mod = opts[:allow]

    unless mod do
      raise "action #{action} of entity #{e[:name]} does not define an :allow option"
    end

    fun_name = String.to_atom("should_#{action}?")

    quote do
      def unquote(fun_name)(
            unquote_splicing(auth_fun_entities_args(e, action)),
            args,
            context
          ) do
        context = Map.drop(context, [:__absinthe_plug__, :loader, :pubsub])

        unquote_splicing(
          case mutating_action?(action) do
            true ->
              e
              |> parent_relations()
              |> Enum.flat_map(fn rel ->
                target = find_entity!(schema, rel[:target])
                context_var = var(rel)

                case optional?(rel) do
                  true ->
                    [
                      quote do
                        context =
                          case unquote(context_var) do
                            nil ->
                              context

                            _ ->
                              (unquote_splicing([
                                 quote do
                                   context =
                                     Map.put(
                                       context,
                                       unquote(target[:name]),
                                       unquote(context_var)
                                     )
                                 end
                                 | ancestor_auth_context(target, schema, context_var)
                               ]))
                          end
                      end
                    ]

                  false ->
                    [
                      quote do
                        context =
                          Map.put(
                            context,
                            unquote(target[:name]),
                            unquote(context_var)
                          )
                      end
                      | ancestor_auth_context(target, schema, context_var)
                    ]
                end
              end)

            false ->
              []
          end
        )

        # if we are updating an entity, then put it also
        # in the authorization context
        unquote_splicing(
          case action == :update || action == :delete do
            true ->
              [
                quote do
                  context = Map.put(context, unquote(e[:name]), unquote(var(e)))
                end
              ]

            false ->
              []
          end
        )

        with false <- unquote(mod).allow?(args, context) do
          {:error, :unauthorized}
        end
      end
    end
  end

  defp with_resolver_inlined_relations_funs(funs, e, schema, _api_module) do
    (Enum.map([:create], fn action ->
       case inlined_children_for_action(e, action) do
         [] ->
           nil

         rels ->
           fun_name = String.to_atom("#{action}_inline_relations")

           [
             quote do
               def unquote(fun_name)(unquote(Macro.var(e[:name], nil)), args, graphql) do
                 with unquote_splicing(
                        Enum.map(rels, fn rel ->
                          quote do
                            :ok <-
                              create_inline_relation(
                                unquote(Macro.var(e[:name], nil)),
                                args,
                                unquote(rel[:name]),
                                graphql
                              )
                          end
                        end)
                      ) do
                   :ok
                 end
               end
             end
             | Enum.map(rels, fn rel ->
                 target = find_entity!(schema, rel[:target])
                 resolver_module = target[:resolver_module]
                 parent_rel = find_relation_by_kind_and_target!(target, :belongs_to, e[:name])

                 children_rels_create =
                   quote do
                     # for now we are assuming this is a list of children,
                     # but we will need to add support for has_one kind of relations too
                     # the most generic case being a list, we will treat both kinds of
                     # relation with the same logic
                     Enum.reduce_while(children, :ok, fn child, _ ->
                       # populate the parent relation
                       # and delete to the child entity resolver
                       child =
                         Map.put(
                           child,
                           unquote(parent_rel[:name]),
                           unquote(Macro.var(e[:name], nil)).id
                         )

                       case unquote(resolver_module).create(
                              graphql.parent,
                              child,
                              graphql.resolution
                            ) do
                         {:ok, _} ->
                           {:cont, :ok}

                         {:error, e} ->
                           {:halt, {:error, e}}
                       end
                     end)
                   end

                 quote do
                   defp create_inline_relation(
                          unquote(Macro.var(e[:name], nil)),
                          args,
                          unquote(rel[:name]),
                          graphql
                        ) do
                     unquote(
                       case optional?(rel) do
                         true ->
                           quote do
                             case Map.get(args, unquote(rel[:name]), nil) do
                               nil ->
                                 :ok

                               children ->
                                 unquote(children_rels_create)
                             end
                           end

                         false ->
                           quote do
                             children = Map.fetch!(args, unquote(rel[:name]))
                             unquote(children_rels_create)
                           end
                       end
                     )
                   end
                 end
               end)
           ]
       end
     end)
     |> List.flatten()
     |> without_nils) ++ funs
  end

  defp with_resolver_list_funs(funs, e, _, api_module) do
    with_entity_funs(funs, e, :list, fn ->
      [
        quote do
          def list(_, args, %{context: context}) do
            with true <- should_list?(args, context) do
              {:ok, unquote(api_module).list(context)}
            end
          end
        end
        | e
          |> parent_relations()
          |> Enum.map(fn rel ->
            fun_name = String.to_atom("list_by_#{rel[:name]}")

            quote do
              def unquote(fun_name)(
                    _,
                    %{unquote(rel[:name]) => arg} = args,
                    %{context: context}
                  ) do
                with true <- should_list?(args, context) do
                  {:ok,
                   unquote(api_module).unquote(fun_name)(
                     arg,
                     context
                   )}
                end
              end
            end
          end)
      ]
    end)
  end

  defp inlined_children_for_action(e, action) do
    e[:relations]
    |> Enum.filter(fn rel ->
      :has_many == rel[:kind] &&
        inline_relation?(rel, action)
    end)
  end

  defp parent_relations(e) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
  end

  defp names(rels) do
    rels
    |> Enum.map(fn rel -> rel[:name] end)
  end

  defp var(name) when is_atom(name) do
    Macro.var(name, __MODULE__)
  end

  defp var(other), do: var(other[:name])

  defp vars(names) do
    Enum.map(names, &var(&1))
  end

  defp with_entity_fetch(e) do
    quote do
      {:ok, unquote(var(e))} <-
        unquote(e[:api_module]).get_by_id(unquote(var(:args)).id)
    end
  end

  defp with_entity_fetch(e, attr) do
    fun_name = String.to_atom("get_by_#{attr}")

    quote do
      {:ok, unquote(var(e))} <-
        unquote(e[:api_module]).unquote(fun_name)(arg)
    end
  end

  # Builds a series of with clauses that fetch entity parent
  # dependencies required in order to either create or update
  # the entity
  defp with_parent_entities_fetch(e, schema) do
    e
    |> parent_relations()
    |> Enum.map(fn rel ->
      case computed?(rel) do
        true ->
          mod = rel[:opts][:using]

          unless mod do
            raise "relation #{rel[:name]} of #{e[:name]} is computed but does not specify a :using option"
          end

          quote do
            {:ok, unquote(var(rel))} = unquote(mod).execute(context)
          end

        false ->
          target = find_entity!(schema, rel[:target])

          quote do
            {:ok, unquote(var(rel))} <-
              unquote(
                case optional?(rel) do
                  false ->
                    quote do
                      unquote(target[:api_module]).get_by_id(unquote(var(:args)).unquote(rel[:name]))
                    end

                  true ->
                    quote do
                      case Map.get(unquote(var(:args)), unquote(rel[:name]), nil) do
                        nil ->
                          {:ok, nil}

                        id ->
                          unquote(target[:api_module]).get_by_id(id)
                      end
                    end
                end
              )
          end
      end
    end)
  end

  # Builds a map of arguments where keys for parent entities
  # have been removed, since they should have already been resolved
  # by their ids.
  defp with_args_without_parents(e) do
    case parent_relations(e) |> names() do
      [] ->
        nil

      names ->
        quote do
          args <- Map.drop(args, unquote(names))
        end
    end
  end

  defp with_args_with_autogenerated_id() do
    quote do
      args <- Map.put(args, :id, Ecto.UUID.generate())
    end
  end

  defp with_args_without_id() do
    quote do
      args <- Map.drop(args, [:id])
    end
  end

  defp with_should(e, action) do
    fun_name = String.to_atom("should_#{action}?")

    quote do
      true <-
        unquote(fun_name)(
          unquote_splicing(auth_fun_entities_args(e, action)),
          args,
          context
        )
    end
  end

  defp with_resolver_create_fun(funs, e, schema, api_module, opts) do
    with_entity_funs(funs, e, :create, fn ->
      inlined_children = inlined_children_for_action(e, :create)

      {parent_var, resolution_var} =
        case inlined_children do
          [] ->
            {quote do
               _parent
             end,
             quote do
               %{context: context}
             end}

          _ ->
            {quote do
               parent
             end,
             quote do
               %{context: context} = resolution
             end}
        end

      quote do
        def create(unquote(parent_var), unquote(var(:args)), unquote(resolution_var)) do
          with unquote_splicing(
                 [
                   with_parent_entities_fetch(e, schema),
                   with_args_without_parents(e),
                   with_args_with_autogenerated_id(),
                   with_should(e, :create)
                 ]
                 |> flat()
                 |> without_nils()
               ) do
            unquote(
              case inlined_children do
                [] ->
                  quote do
                    unquote(api_module).create(
                      unquote_splicing((e |> parent_relations() |> names() |> vars()) ++ [var(:args)])
                    )
                  end

                children ->
                  nil

                  quote do
                    {children_args, args} =
                      Map.split(
                        args,
                        unquote(names(children))
                      )

                    unquote(opts[:repo]).transaction(fn ->
                      with {:ok, unquote(var(e))} <-
                             unquote(api_module).create(
                               unquote_splicing((e |> parent_relations() |> names() |> vars()) ++ [var(:args)])
                             ),
                           :ok <-
                             create_inline_relations(
                               unquote(var(e)),
                               children_args,
                               %{parent: parent, resolution: resolution}
                             ) do
                        unquote(var(e))
                      else
                        {:error, changeset} ->
                          unquote(opts[:repo]).rollback(changeset)
                      end
                    end)
                  end
              end
            )
          end
        end
      end
    end)
  end

  defp with_resolver_update_fun(funs, e, schema, api_module) do
    with_entity_funs(funs, e, :update, fn ->
      quote do
        def update(_parent, unquote(var(:args)), %{context: context}) do
          with unquote_splicing(
                 [
                   with_entity_fetch(e),
                   with_parent_entities_fetch(e, schema),
                   with_args_without_parents(e),
                   with_args_without_id(),
                   with_should(e, :update)
                 ]
                 |> flat()
                 |> without_nils()
               ) do
            unquote(api_module).update(
              unquote_splicing((e |> parent_relations() |> names() |> vars()) ++ [var(e), var(:args)])
            )
          end
        end
      end
    end)
  end

  defp with_resolver_delete_fun(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :delete, fn ->
      quote do
        def delete(_parent, unquote(var(:args)), %{context: context}) do
          with unquote_splicing(
                 [
                   with_entity_fetch(e),
                   with_should(e, :delete)
                 ]
                 |> flat()
                 |> without_nils()
               ) do
            unquote(api_module).delete(unquote(var(e)))
          end
        end
      end
    end)
  end

  defp with_resolver_custom_funs(funs, e, schema, api_module) do
    Enum.map(e[:custom_actions], fn {action, opts} ->
      resolver_custom_fun(e, action, opts, api_module, schema)
    end) ++ funs
  end

  defp resolver_custom_fun(e, action, _opts, api_module, _schema) do
    quote do
      def unquote(action)(_, args, %{context: context}) do
        with unquote_splicing([
               with_should(e, action)
             ]) do
          args =
            case Map.get(args, :id, nil) do
              nil ->
                Map.put(args, :id, Ecto.UUID.generate())

              _ ->
                args
            end

          unquote(api_module).unquote(action)(args)
        end
      end
    end
  end

  defp resolver_module(e, schema, opts) do
    api_module = e[:api_module]

    resolver_funs =
      []
      |> with_resolver_auth_funs(e, schema)
      |> with_resolver_inlined_relations_funs(e, schema, api_module)
      |> with_resolver_list_funs(e, schema, api_module)
      |> with_resolver_read_funs(e, schema, api_module)
      |> with_resolver_create_fun(e, schema, api_module, opts)
      |> with_resolver_update_fun(e, schema, api_module)
      |> with_resolver_delete_fun(e, schema, api_module)
      |> with_resolver_custom_funs(e, schema, api_module)
      |> List.flatten()

    quote do
      defmodule unquote(e[:resolver_module]) do
        (unquote_splicing(resolver_funs))
      end
    end
  end

  defp api_module(e, schema, opts) do
    schema_module = e[:schema_module]
    repo_module = opts[:repo]

    api_funs =
      []
      |> with_api_list_funs(e, schema_module, repo_module, schema)
      |> with_api_read_funs(e, schema_module, repo_module, schema)
      |> with_api_create_fun(e, schema_module, repo_module, schema)
      |> with_api_update_fun(e, schema_module, repo_module, schema)
      |> with_api_delete_fun(e, schema_module, repo_module, schema)
      |> with_api_custom_funs(e, schema_module, repo_module, schema)
      |> List.flatten()

    quote do
      defmodule unquote(e[:api_module]) do
        import Ecto.Query, only: [from: 2]
        (unquote_splicing(api_funs))
      end
    end
  end

  defp with_entity_scope(e, action, fun) do
    case action_for(e, action) do
      nil ->
        fun.()

      opts ->
        case opts[:scope] do
          nil ->
            fun.()

          mod ->
            quote do
              query = unquote(mod).scope(query, context)
              unquote(fun.())
            end
        end
    end
  end

  defp with_api_list_funs(funs, e, schema_module, repo_module, _schema \\ nil) do
    [
      quote do
        def list(context) do
          query = unquote(schema_module)

          unquote(
            with_entity_scope(e, :list, fn ->
              quote do
                unquote(repo_module).all(query)
              end
            end)
          )
        end
      end
      | e[:relations]
        |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
        |> Enum.map(fn rel ->
          quote do
            def unquote(String.to_atom("list_by_#{rel[:name]}"))(id, context) do
              query =
                from(unquote(Macro.var(rel[:name], nil)) in unquote(schema_module),
                  where: unquote(Macro.var(rel[:name], nil)).unquote(String.to_atom("#{rel[:name]}_id")) == ^id
                )

              unquote(
                with_entity_scope(e, :list, fn ->
                  quote do
                    unquote(repo_module).all(query)
                  end
                end)
              )
            end
          end
        end)
    ] ++ funs
  end

  defp entity_read_preloads(e, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
    |> Enum.map(fn rel ->
      target = find_entity!(schema, rel[:target])

      # recursively resolve ancestors preloads
      # this will be needed in order to build a full context
      # for authorization purposes.
      case entity_read_preloads(target, schema) do
        [] ->
          rel[:name]

        parent_preloads ->
          {rel[:name], parent_preloads}
      end
    end)
  end

  defp with_api_read_funs(funs, e, schema_module, repo_module, schema) do
    [
      quote do
        def get_by_id(id) do
          case unquote(schema_module)
               |> unquote(repo_module).get(id)
               |> unquote(repo_module).preload(unquote(entity_read_preloads(e, schema))) do
            nil ->
              {:error, :not_found}

            e ->
              {:ok, e}
          end
        end
      end
      | e[:attributes]
        |> Enum.filter(&unique?(&1))
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
                   |> unquote(repo_module).get_by([{unquote(attr[:name]), value}])
                   |> unquote(repo_module).preload(unquote(entity_read_preloads(e, schema))) do
                nil ->
                  {:error, :not_found}

                e ->
                  {:ok, e}
              end
            end
          end
        end)
    ] ++ funs
  end

  defp before_hook(e, action) do
    opts =
      e[:actions][action] ||
        e[:custom_actions][action]

    case opts[:before] do
      nil ->
        nil

      mods when is_list(mods) ->
        quote do
          (unquote_splicing(
             Enum.map(mods, fn mod ->
               quote do
                 {:ok, attrs} = unquote(mod).execute(attrs)
               end
             end)
           ))
        end

      mod ->
        quote do
          {:ok, attrs} = unquote(mod).execute(attrs)
        end
    end
  end

  defp after_hook(e, action) do
    opts =
      e[:actions][action] ||
        e[:custom_actions][action]

    case opts[:after] do
      nil ->
        nil

      mods when is_list(mods) ->
        quote do
          with {:ok, res} <- result do
            (unquote_splicing(
               Enum.map(mods, fn mod ->
                 quote do
                   unquote(mod).execute(res)
                 end
               end)
             ))
          end
        end

      mod when is_atom(mod) ->
        quote do
          with {:ok, res} <- result do
            unquote(mod).execute(res)
          end
        end
    end
  end

  defp with_api_create_fun(funs, e, schema_module, repo_module, _schema) do
    fun_body =
      case virtual?(e) do
        true ->
          quote do
            result = unquote(e[:actions][:create][:using]).execute(attrs)
          end

        false ->
          quote do
            result =
              with {:ok, e} <-
                     %unquote(schema_module){}
                     |> unquote(schema_module).changeset(attrs)
                     |> unquote(repo_module).insert() do
                get_by_id(e.id)
              end
          end
      end

    [
      quote do
        def create(
              unquote_splicing(
                e
                |> parent_relations()
                |> vars()
              ),
              attrs
            ) do
          unquote_splicing(
            e
            |> parent_relations()
            |> Enum.map(fn rel ->
              quote do
                attrs =
                  attrs
                  |> Map.put(
                    unquote(String.to_atom("#{rel[:name]}_id")),
                    unquote(
                      case optional?(rel) do
                        true ->
                          quote do
                            case unquote(var(rel)) do
                              nil ->
                                nil

                              _ ->
                                unquote(var(rel)).id
                            end
                          end

                        false ->
                          quote do
                            unquote(var(rel)).id
                          end
                      end
                    )
                  )
              end
            end)
          )

          unquote(before_hook(e, :create))
          unquote(fun_body)
          unquote(after_hook(e, :create))
          result
        end
      end
      | funs
    ]
  end

  defp with_api_update_fun(funs, e, schema_module, repo_module, _schema) do
    fun_body =
      quote do
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

        result =
          with {:ok, unquote(Macro.var(e[:name], nil))} <-
                 unquote(Macro.var(e[:name], nil))
                 |> unquote(schema_module).changeset(attrs)
                 |> unquote(repo_module).update() do
            get_by_id(unquote(Macro.var(e[:name], nil)).id)
          end
      end

    [
      quote do
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
          unquote(before_hook(e, :update))
          unquote(fun_body)
          unquote(after_hook(e, :update))
          result
        end
      end
      | funs
    ]
  end

  defp with_api_delete_fun(funs, _e, schema_module, repo_module, _schema) do
    [
      quote do
        def delete(%unquote(schema_module){} = e) do
          e
          |> unquote(schema_module).delete_changeset()
          |> unquote(repo_module).delete()
        end
      end
      | funs
    ]
  end

  defp with_api_custom_funs(funs, e, schema_module, repo_module, _schema) do
    Enum.map(e[:custom_actions], fn {action, opts} ->
      api_custom_fun(e, action, opts, schema_module, repo_module)
    end) ++ funs
  end

  defp api_custom_fun(e, action, opts, _schema_module, _repo_module) do
    using_mod = opts[:using]

    unless using_mod do
      raise "custom action #{action} of #{e[:name]} does not define a :using option"
    end

    fun_body =
      quote do
        result = unquote(opts[:using]).execute(attrs)
      end

    quote do
      def unquote(action)(attrs) do
        (unquote_splicing(
           without_nils([
             before_hook(e, action),
             fun_body,
             after_hook(e, action)
           ])
         ))

        result
      end
    end
  end

  defp find_entity!(schema, name) do
    case Enum.filter(schema, fn e ->
           name == e[:name]
         end) do
      [] ->
        raise "Could not resolve entity #{name}: #{inspect(Enum.map(schema, fn e -> e[:name] end))}"

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

  defp unit_graphql_object() do
    quote do
      object :unit do
        field(:id, non_null(:id))
      end
    end
  end

  defp graphql_attribute_fields(e, _schema, opts \\ []) do
    e[:attributes]
    |> Enum.reject(fn attr ->
      Enum.member?(opts[:skip] || [], attr[:name])
    end)
    |> Enum.reject(&private?(&1))
    |> Enum.map(fn attr ->
      # determine the kind for this field, depending
      # on whether it is an enum or not
      kind = attr_graphql_type(e, attr)

      kind =
        case attr[:opts][:allow] do
          nil ->
            case optional?(attr) do
              true ->
                quote do
                  unquote(kind)
                end

              false ->
                quote do
                  non_null(unquote(kind))
                end
            end

          _ ->
            kind
        end

      quote do
        field(unquote(attr[:name]), unquote(kind))
      end
    end)
  end

  defp graphql_relation_fields(e, _schema, opts) do
    e[:relations]
    |> Enum.reject(fn rel ->
      Enum.member?(opts[:skip] || [], rel[:target])
    end)
    |> Enum.map(fn rel ->
      optional =
        optional?(rel) ||
          rel[:opts][:allow] != nil

      kind =
        case {rel[:kind], optional} do
          {:has_many, true} ->
            quote do
              list_of(unquote(rel[:target]))
            end

          {:has_many, false} ->
            quote do
              list_of(non_null(unquote(rel[:target])))
            end

          {_, true} ->
            quote do
              unquote(rel[:target])
            end

          {_, false} ->
            quote do
              non_null(unquote(rel[:target]))
            end
        end

      case opts[:mode] do
        :input ->
          case optional?(rel) do
            false ->
              quote do
                field(
                  unquote(rel[:name]),
                  non_null(:id)
                )
              end

            true ->
              quote do
                field(
                  unquote(rel[:name]),
                  :id
                )
              end
          end

        _ ->
          quote do
            field(
              unquote(rel[:name]),
              unquote(kind),
              resolve: dataloader(unquote(opts[:caller]).Dataloader.Repo)
            )
          end
      end
    end)
  end

  defp graphql_object(e, schema, opts) do
    quote do
      object unquote(e[:name]) do
        (unquote_splicing(
           graphql_attribute_fields(e, schema, opts) ++
             graphql_relation_fields(e, schema, opts)
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

  @readonly_actions [:read, :list]

  defp readonly_action?(name) do
    Enum.member?(@readonly_actions, name)
  end

  defp mutating_action?(name) do
    name != :delete &&
      !readonly_action?(name)
  end

  defp action_names(e) do
    (e[:actions] ++ e[:custom_actions])
    |> Enum.map(fn {name, _} -> name end)
  end

  defp mutations?(e) do
    e
    |> action_names()
    |> Enum.reject(&readonly_action?(&1))
    |> Enum.count() > 0
  end

  defp action?(e, action) do
    e
    |> action_names()
    |> Enum.find(fn name ->
      action == name
    end) != nil
  end

  defp action_for(e, action) do
    (e[:actions] ++ e[:custom_actions])
    |> Enum.filter(fn {name, _} ->
      name == action
    end)
    |> Enum.map(fn {_, opts} -> opts end)
    |> List.first()
  end

  defp single_graphql_queries(e, schema) do
    case action?(e, :read) do
      true ->
        quote do
          object unquote(String.to_atom("#{e[:name]}_queries")) do
            (unquote_splicing(
               List.flatten([
                 graphql_query_find_by_id(e, schema),
                 graphql_query_find_by_unique_fields(e, schema)
               ])
             ))
          end
        end

      false ->
        nil
    end
  end

  defp multiple_graphql_queries(e, schema) do
    case action?(e, :list) do
      true ->
        quote do
          object unquote(String.to_atom("#{e[:plural]}_queries")) do
            (unquote_splicing(
               List.flatten([
                 graphql_query_list_all(e, schema),
                 graphql_query_find_by_parent_types(e, schema)
               ])
             ))
          end
        end

      false ->
        nil
    end
  end

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural_display_name]}")
      field :all, list_of(unquote(e[:name])) do
        resolve(&unquote(e[:resolver_module]).list/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field :by_id,
            unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).get_by_id/3)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(&unique?(&1))
    |> Enum.map(fn attr ->
      kind = attr_graphql_type(e, attr)

      quote do
        @desc "Find a single " <>
                unquote("#{e[:display_name]}") <>
                " given its unique " <> unquote("#{attr[:name]}")
        field unquote(String.to_atom("by_#{attr[:name]}")),
              unquote(e[:name]) do
          arg(unquote(attr[:name]), non_null(unquote(kind)))

          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("get_by_#{attr[:name]}")) / 3))
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
        field unquote(String.to_atom("by_#{rel[:name]}")),
              list_of(unquote(e[:name])) do
          arg(unquote(rel[:name]), non_null(:id))

          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("list_by_#{rel[:name]}")) / 3))
        end
      end
    end)
  end

  defp graphql_input_types(e, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :has_many == rel[:kind] && inline_relation?(rel, :create) end)
    |> Enum.map(fn rel ->
      target = find_entity!(schema, rel[:target])
      input_type = String.to_atom("#{target[:name]}_input")

      quote do
        input_object unquote(input_type) do
          (unquote_splicing(
             graphql_attribute_fields(target, schema, skip: [:id]) ++
               graphql_relation_fields(target, schema,
                 mode: :input,
                 skip: [
                   e[:name]
                 ]
               )
           ))
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    case mutations?(e) do
      false ->
        nil

      true ->
        quote do
          object unquote(String.to_atom("#{e[:name]}_mutations")) do
            (unquote_splicing(
               List.flatten(
                 [
                   with_entity_action(e, :create, fn _ -> graphql_create_mutation(e, schema) end),
                   with_entity_action(e, :update, fn _ -> graphql_update_mutation(e, schema) end),
                   with_entity_action(e, :delete, fn _ -> graphql_delete_mutation(e, schema) end)
                 ] ++ graphql_custom_mutations(e, schema)
               )
               |> without_nils()
             ))
          end
        end
    end
  end

  defp graphql_custom_mutations(e, schema) do
    e[:custom_actions]
    |> Enum.map(fn {action, opts} ->
      graphql_custom_mutation(e, action, opts, schema)
    end)
  end

  defp computed?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :computed)
  end

  defp optional?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :optional)
  end

  defp unique?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :unique)
  end

  def graphql_resolver(e, action) do
    quote do
      &(unquote(e[:resolver_module]).unquote(action) / 3)
    end
  end

  defp inline_relation?(rel, action) do
    Enum.member?(rel[:opts][:inline] || [], action)
  end

  defp graphql_create_mutation(e, _schema) do
    return_type =
      case e[:actions][:create][:produces] do
        nil ->
          e[:name]

        type ->
          type
      end

    quote do
      @desc unquote("Create a new #{e[:display_name]}")
      field :create, non_null(unquote(return_type)) do
        unquote_splicing(
          (e[:attributes]
           |> Enum.reject(fn attr -> attr[:name] == :id end)
           |> Enum.reject(&computed?(&1))
           |> Enum.map(fn attr ->
             kind = attr_graphql_type(e, attr)

             quote do
               arg(
                 unquote(attr[:name]),
                 unquote(
                   case optional?(attr) do
                     true ->
                       kind

                     false ->
                       quote do
                         non_null(unquote(kind))
                       end
                   end
                 )
               )
             end
           end)) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.reject(&computed?(&1))
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), non_null(:id))
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel ->
               :has_many == rel[:kind] && inline_relation?(rel, :create)
             end)
             |> Enum.map(fn rel ->
               input_type = String.to_atom("#{rel[:target]}_input")

               quote do
                 arg(unquote(rel[:name]), list_of(non_null(unquote(input_type))))
               end
             end))
        )

        resolve(unquote(graphql_resolver(e, :create)))
      end
    end
  end

  defp graphql_update_mutation(e, _schema) do
    quote do
      @desc unquote("Update an existing #{e[:display_name]}")
      field :update, non_null(unquote(e[:name])) do
        unquote_splicing(
          [
            quote do
              arg(:id, non_null(:id))
            end
          ] ++
            (e[:attributes]
             |> Enum.reject(fn attr ->
               attr[:name] == :id || computed?(attr)
             end)
             |> Enum.map(fn attr ->
               kind = attr_graphql_type(e, attr)

               quote do
                 arg(
                   unquote(attr[:name]),
                   unquote(kind)
                 )
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.reject(&computed?(&1))
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), :id)
               end
             end))
        )

        resolve(unquote(graphql_resolver(e, :update)))
      end
    end
  end

  defp graphql_delete_mutation(e, _schema) do
    quote do
      @desc "Delete an existing " <> unquote("#{e[:display_name]}")
      field :delete, unquote(e[:name]) do
        arg(:id, non_null(:id))

        resolve(unquote(graphql_resolver(e, :delete)))
      end
    end
  end

  defp entity_attribute(e, name) do
    Enum.find(e[:attributes], fn attr ->
      name == attr[:name]
    end)
  end

  defp graphql_custom_mutation(e, action, opts, _schema) do
    unless opts[:args] do
      raise "Custom action #{action} in #{e[:name]} has no arguments"
    end

    unless opts[:produces] do
      raise "Custom action #{action} in #{e[:name]} does not define an output type. Please set a :produces kind"
    end

    quote do
      @desc "Custom action"
      field unquote(action), non_null(unquote(opts[:produces])) do
        (unquote_splicing(
           Enum.map(opts[:args], fn
             {arg, kind} ->
               quote do
                 arg(unquote(arg), non_null(unquote(kind)))
               end

             arg ->
               kind =
                 case entity_attribute(e, arg) do
                   nil ->
                     :id

                   attr ->
                     attr_graphql_type(e, attr)
                 end

               quote do
                 arg(unquote(arg), non_null(unquote(kind)))
               end
           end)
         ))

        resolve(unquote(graphql_resolver(e, action)))
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
        [name: name, kind: :has_many, opts: [], plural: name]

      {:has_many, _, [name, opts]} ->
        [name: name, kind: :has_many, opts: opts, plural: name]

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

  defp with_action_hook(opts, name) do
    case opts[name] do
      nil ->
        opts

      {:__aliases__, _, mod} ->
        Keyword.put(opts, name, Module.concat(mod))

      mods when is_list(mods) ->
        Keyword.put(
          opts,
          name,
          Enum.map(mods, fn {:__aliases__, _, mod} ->
            Module.concat(mod)
          end)
        )
    end
  end

  defp actions_from({:__block__, [], actions}) do
    actions
    |> Enum.reduce([], fn
      {:action, _, [name, opts]}, acc ->
        opts =
          opts
          |> with_action_hook(:using)
          |> with_action_hook(:before)
          |> with_action_hook(:after)
          |> with_action_hook(:allow)

        Keyword.put(acc, name, opts)

      _, acc ->
        acc
    end)
    |> without_nils()
  end

  defp actions_from(_), do: []
end
