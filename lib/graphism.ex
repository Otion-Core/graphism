defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias Graphism.Migrations

  require Logger

  defmacro __using__(opts \\ []) do
    Code.compiler_options(ignore_module_conflict: true)

    Module.register_attribute(__CALLER__.module, :data,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :hooks,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :schema_imports,
      accumulate: true,
      persist: true
    )

    repo = opts[:repo]

    if repo != nil do
      Module.register_attribute(__CALLER__.module, :repo,
        accumulate: false,
        persist: true
      )

      Module.put_attribute(__CALLER__.module, :repo, repo)

      alias Dataloader, as: DL

      middleware =
        Enum.map(opts[:middleware] || [], fn {:__aliases__, _, mod} ->
          Module.concat(mod)
        end)

      quote do
        defmodule Dataloader.Repo do
          @queryables unquote(__CALLER__.module).DataloaderQueries

          def data do
            DL.Ecto.new(unquote(repo), query: &query/2)
          end

          def query(queryable, params) do
            @queryables.query(queryable, params)
          end
        end

        import unquote(__MODULE__), only: :macros
        @before_compile unquote(__MODULE__)

        use Absinthe.Schema
        import Absinthe.Resolution.Helpers, only: [dataloader: 1]
        import_types(Absinthe.Type.Custom)
        import_types(Absinthe.Plug.Types)
        import_types(Graphism.Type.Graphql.Json)

        @sources [unquote(__CALLER__.module).Dataloader.Repo]
        @fields_auth unquote(__CALLER__.module).FieldsAuth
        @middleware unquote(middleware)

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

        def middleware(middleware, _field, _object) do
          @middleware ++ middleware ++ [@fields_auth, Graphism.ErrorMiddleware]
        end
      end
    else
      quote do
        import unquote(__MODULE__), only: :macros
        @before_compile unquote(__MODULE__)
      end
    end
  end

  defmacro __before_compile__(_) do
    caller_module = __CALLER__.module

    repo =
      caller_module
      |> Module.get_attribute(:repo)

    unless repo do
      []
    else
      schema_imports =
        caller_module
        |> Module.get_attribute(:schema_imports)
        |> Enum.flat_map(fn mod ->
          :attributes
          |> mod.__info__()
          |> Enum.filter(fn {name, _} -> name == :schema end)
          |> Enum.map(fn {_, e} -> e end)
          |> Enum.map(fn e ->
            schema_module_alias = e[:schema_module] |> Module.split() |> List.last()
            schema_module = Module.split(caller_module) ++ [schema_module_alias]

            e
            |> Keyword.put(:schema_module, Module.concat(schema_module))
            |> Keyword.put(:resolver_module, Module.concat(schema_module ++ [Resolver]))
            |> Keyword.put(:api_module, Module.concat(schema_module ++ [Api]))
          end)
        end)

      schema =
        caller_module
        |> Module.get_attribute(:schema)
        |> Kernel.++(schema_imports)
        |> resolve()

      data_imports =
        caller_module
        |> Module.get_attribute(:schema_imports)
        |> Enum.flat_map(fn mod ->
          :attributes
          |> mod.__info__()
          |> Enum.filter(fn {name, _} -> name == :data end)
          |> Enum.flat_map(fn {_, data} -> data end)
        end)

      data =
        caller_module
        |> Module.get_attribute(:data)
        |> Keyword.merge(data_imports)

      hooks_imports =
        caller_module
        |> Module.get_attribute(:schema_imports)
        |> Enum.flat_map(fn mod ->
          :attributes
          |> mod.__info__()
          |> Enum.filter(fn {name, _} -> name == :hooks end)
          |> Enum.flat_map(fn {_, hooks} -> hooks end)
        end)

      hooks =
        caller_module
        |> Module.get_attribute(:hooks)
        |> Kernel.++(hooks_imports)

      enums =
        data
        |> Enum.filter(fn {_, values} -> is_list(values) end)

      default_allow_hook = hook(hooks, :allow, :default)

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

      dataloader_queries =
        quote do
          defmodule DataloaderQueries do
            import Ecto.Query, only: [from: 2]

            (unquote_splicing(
               Enum.map(schema, fn e ->
                 schema_module = e[:schema_module]
                 preloads = preloads(e)

                 quote do
                   def query(unquote(schema_module) = schema, _) do
                     from(q in schema,
                       preload: unquote(preloads)
                     )
                   end
                 end
               end)
             ))
          end
        end

      schema_settings =
        quote do
          defmodule FieldsAuth do
            @behaviour Absinthe.Middleware
            alias Absinthe.Blueprint.Document.Field

            def call(
                  %{
                    definition: %Field{
                      schema_node: %Absinthe.Type.Field{identifier: field},
                      parent_type: %Absinthe.Type.Object{identifier: entity}
                    }
                  } = resolution,
                  _
                ),
                do: auth(entity, field, resolution)

            def call(resolution, _), do: resolution

            unquote_splicing(
              Enum.flat_map(schema, fn e ->
                entity_attributes_auth(e, default_allow_hook) ++
                  entity_belongs_to_relations_auth(e, default_allow_hook, schema) ++
                  entity_has_many_relations_auth(e, default_allow_hook, schema)
              end)
            )

            defp auth(_, _, resolution), do: resolution
            defp maybe_with(map, _key, nil), do: map
            defp maybe_with(map, key, value), do: Map.put(map, key, value)
          end
        end

      enums_fun =
        quote do
          def enums() do
            unquote(enums)
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
          api_module(e, schema, hooks, repo: repo, caller: __CALLER__)
        end)

      resolver_modules =
        Enum.map(schema, fn e ->
          resolver_module(e, schema,
            repo: repo,
            hooks: hooks,
            caller: __CALLER__
          )
        end)

      asc_desc = {:asc_desc, [:asc, :desc]}

      enum_types =
        Enum.map([asc_desc | enums], fn {enum, value} ->
          graphql_enum(enum, value)
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

      aggregate_graphql_type =
        quote do
          object :aggregate do
            field :count, :integer
          end
        end

      entities_queries =
        Enum.flat_map(schema, fn e ->
          [
            single_graphql_queries(e, schema),
            multiple_graphql_queries(e, schema)
          ]
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
                   with_entity_action(e, :list, fn _ ->
                     quote do
                       field unquote(String.to_atom("#{e[:plural]}")),
                             non_null(unquote(String.to_atom("#{e[:plural]}_queries"))) do
                         resolve(&Resolver.Self.itself/3)
                       end
                     end
                   end),
                   with_entity_action(e, :read, fn _ ->
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
               |> raise_if_empty(
                 "No GraphQL queries could be extracted from your schema. Please ensure you have :read or :list actions in your entities"
               )
             ))
          end
        end

      input_types =
        schema
        |> Enum.reject(&internal?(&1))
        |> Enum.flat_map(fn e ->
          [
            graphql_input_types(e, schema),
            graphql_update_input_types(e, schema)
          ]
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
               |> raise_if_empty(
                 "No GraphQL mutations could be extracted from your schema. Please ensure you have actions in your entities other than :read and :list."
               )
             ))
          end
        end

      List.flatten([
        dataloader_queries,
        schema_settings,
        enums_fun,
        schema_fun,
        schema_empty_modules,
        schema_modules,
        api_modules,
        resolver_modules,
        enum_types,
        input_types,
        objects,
        self_resolver,
        aggregate_graphql_type,
        entities_queries,
        queries,
        entities_mutations,
        mutations
      ])
    end
  end

  def entity_attributes_auth(e, default_allow_hook) do
    Enum.map(e[:attributes], fn attr ->
      entity_name = e[:name]
      field_name = attr[:name]
      mod = attr[:opts][:allow] || default_allow_hook
      schema_module = e[:schema_module]

      quote do
        defp auth(unquote(entity_name), unquote(field_name), resolution) do
          graphism = %{
            entity: unquote(entity_name),
            field: unquote(field_name),
            schema: unquote(schema_module)
          }

          context =
            resolution.context
            |> Map.drop([:pubsub, :loader, :__absinthe_plug__])
            |> Map.put(:graphism, graphism)
            |> Map.put(unquote(entity_name), resolution.source)

          case unquote(mod).allow?(resolution.value, context) do
            true ->
              resolution

            false ->
              Absinthe.Resolution.put_result(resolution, {:error, :unauthorized})
          end
        end
      end
    end)
  end

  def entity_belongs_to_relations_auth(e, default_allow_hook, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
    |> Enum.map(fn rel ->
      entity_name = e[:name]
      field_name = rel[:name]
      target_entity = rel[:target]
      mod = rel[:opts][:allow] || default_allow_hook
      schema_module = e[:schema_module]
      target_schema_module = find_entity!(schema, target_entity)[:schema_module]

      quote do
        defp auth(unquote(entity_name), unquote(field_name), resolution) do
          graphism = %{
            entity: unquote(entity_name),
            field: unquote(field_name),
            target_entity: unquote(target_entity),
            schema: unquote(schema_module),
            target_schema: unquote(target_schema_module)
          }

          field_value = Map.get(resolution.source, unquote(field_name))

          context =
            resolution.context
            |> Map.drop([:pubsub, :loader, :__absinthe_plug__])
            |> Map.put(:graphism, graphism)
            |> Map.put(unquote(field_name), field_value)
            |> Map.put(unquote(entity_name), resolution.source)

          case unquote(mod).allow?(resolution.value, context) do
            true ->
              resolution

            false ->
              Absinthe.Resolution.put_result(resolution, {:error, :unauthorized})
          end
        end
      end
    end)
  end

  def entity_has_many_relations_auth(e, default_allow_hook, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
    |> Enum.map(fn rel ->
      entity_name = e[:name]
      field_name = rel[:name]
      target_entity = rel[:target]
      mod = rel[:opts][:allow] || default_allow_hook
      schema_module = e[:schema_module]
      target_schema_module = find_entity!(schema, target_entity)[:schema_module]

      quote do
        defp auth(unquote(entity_name), unquote(field_name), resolution) do
          graphism = %{
            entity: unquote(entity_name),
            field: unquote(field_name),
            target_entity: unquote(target_entity),
            schema: unquote(schema_module),
            target_schema: unquote(target_schema_module)
          }

          context =
            resolution.context
            |> Map.drop([:pubsub, :loader, :__absinthe_plug__])
            |> Map.put(:graphism, graphism)
            |> Map.put(unquote(entity_name), resolution.source)

          value =
            Enum.filter(resolution.value, fn value ->
              context = Map.put(context, unquote(field_name), value)
              unquote(mod).allow?(value, context)
            end)

          %{resolution | value: value}
        end
      end
    end)
  end

  defmacro import_schema({:__aliases__, _, module}) do
    Module.put_attribute(__CALLER__.module, :schema_imports, Module.concat(module))
  end

  defmacro allow({:__aliases__, _, module}) do
    hook = %{
      kind: :allow,
      name: :default,
      desc: "Default hook for authorization",
      module: Module.concat(module)
    }

    Module.put_attribute(__CALLER__.module, :hooks, hook)
  end

  defp hook(hooks, kind, name) do
    with hook when hook != nil <- Enum.find(hooks, &(&1.kind == kind and &1.name == name)) do
      hook.module
    end
  end

  defmacro entity(name, opts \\ [], do: block) do
    caller_module = __CALLER__.module

    attrs =
      attributes_from(block)
      |> maybe_add_id_attribute()

    rels = relations_from(block)
    actions = actions_from(block, name)
    keys = keys_from(block)

    {actions, custom_actions} = split_actions(actions)

    entity =
      [
        name: name,
        attributes: attrs,
        relations: rels,
        keys: keys,
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
      |> maybe_with_scope()

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

  defmacro belongs_to(_name, _opts \\ []) do
  end

  defmacro key(_fields, _opts \\ []) do
  end

  defmacro index(_opts \\ []) do
  end

  defmacro action(_name, _opts \\ []) do
  end

  defmacro data(name, value) do
    Module.put_attribute(__CALLER__.module, :data, {name, value})
  end

  defmacro unique(_name, _opts \\ []) do
  end

  defmacro optional(_attr, _opts \\ []) do
  end

  defmacro maybe(_attr, _opts \\ []) do
  end

  defmacro private(_attr, _opts \\ []) do
  end

  defmacro computed(_attr, _opts \\ []) do
  end

  defmacro string(_name, _opts \\ []) do
  end

  defmacro text(_name, _opts \\ []) do
  end

  defmacro integer(_name, _opts \\ []) do
  end

  defmacro float(_name, _opts \\ []) do
  end

  defmacro boolean(_name, _opts \\ []) do
  end

  defmacro datetime(_name, _opts \\ []) do
  end

  defmacro date(_name, _opts \\ []) do
  end

  defmacro decimal(_name, _opts \\ []) do
  end

  defmacro preloaded(_name, _opts \\ []) do
  end

  defmacro upload(_name, _opts \\ []) do
  end

  defmacro immutable(_name, _opts \\ []) do
  end

  defmacro non_empty(_name, _opts \\ []) do
  end

  defmacro virtual(_name, _opts \\ []) do
  end

  defmacro json(_name, _opts \\ []) do
  end

  defp without_nils(enum) do
    Enum.reject(enum, fn item -> item == nil end)
  end

  defp raise_if_empty(enum, msg) do
    if Enum.empty?(enum) do
      raise msg
    end

    enum
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
    :boolean,
    :upload,
    :json
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

  defp maybe_with_scope(entity) do
    (entity[:opts][:scope] || [])
    |> Enum.each(fn name ->
      relation!(entity, name)
    end)

    entity
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

  defp client_ids?(e), do: modifier?(e, :client_ids)
  defp virtual?(e), do: modifier?(e, :virtual)
  defp internal?(e), do: modifier?(e, :internal)
  defp private?(attr), do: modifier?(attr, :private)

  defp modifier?(any, modifier), do: any |> modifiers() |> Enum.member?(modifier)
  defp modifiers(any), do: any[:opts][:modifiers] || []

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
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(plurals))}. Relation: #{inspect(rel)}"
              end

              rel
              |> Keyword.put(:target, target)
              |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

            _ ->
              target = index[rel[:name]]

              unless target do
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(index))}"
              end

              name = rel[:opts][:as] || rel[:name]

              rel
              |> Keyword.put(:target, target[:name])
              |> Keyword.put(:name, name)
              |> Keyword.put(:column, String.to_atom("#{name}_id"))
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

  defp default_value(true), do: true
  defp default_value(false), do: false
  defp default_value(v) when is_atom(v), do: "#{v}"
  defp default_value(v), do: v

  defp ecto_datatype(:datetime), do: :utc_datetime
  defp ecto_datatype(other), do: other

  defp schema_module(e, schema, _opts) do
    indices = Migrations.indices_from_attributes(e) ++ Migrations.indices_from_keys(e)
    stored_attributes = Enum.reject(e[:attributes], fn attr -> attr[:name] == :id or virtual?(attr) end)
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
            target = find_entity!(schema, rel[:target])
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
              target = find_entity!(schema, rel[:target])
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
                  inverse_rel = inverse_relation!(schema, e, rel[:name])
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
                            |> Enum.reject(&((optional?(&1) && !non_empty?(&1)) || virtual?(&1)))
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
                                rel[:kind] == :belongs_to
                              end)
                              |> Enum.filter(&optional?(&1))
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @all_fields @required_fields ++ @optional_fields

        @computed_fields unquote(
                           (e[:attributes] || e[:relations])
                           |> Enum.filter(&computed?(&1))
                           |> Enum.map(fn field ->
                             field[:name]
                           end)
                         )

        def required_fields, do: @required_fields
        def optional_fields, do: @optional_fields
        def computed_fields, do: @computed_fields

        unquote_splicing(
          (names(stored_attributes) ++ [:inserted_at, :updated_at])
          |> Enum.map(&attribute_field_spec_ast(e, &1, schema))
        )

        unquote_splicing(
          e
          |> relations()
          |> names()
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
            |> parent_relations()
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

  defp attribute_field_spec_ast(e, field, _schema) do
    duck_cased = to_string(field)
    camel_cased = Inflex.camelize(field, :lower)

    {column_name, type} =
      if field in [:inserted_at, :updated_at] do
        {field, :timestamp}
      else
        attr = attribute!(e, field)
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
    rel = relation!(e, field)
    target_name = rel[:target]
    target = find_entity!(schema, target_name)
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
    |> relations()
    |> Enum.group_by(fn rel ->
      kind = rel[:kind]
      schema = find_entity!(schema, rel[:target])[:schema_module]
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
    |> parent_relations()
    |> Enum.reject(fn rel -> rel[:target] == e[:name] end)
    |> Enum.map(fn rel ->
      {
        rel[:name],
        schema
        |> find_entity!(rel[:target])
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
        get_by_id_resolver_fun(e)
      ] ++ get_by_key_resolver_funs(e) ++ get_by_attribute_resolver_funs(e)
    end)
  end

  defp get_by_id_resolver_fun(e) do
    quote do
      def get_by_id(_, args, %{context: context}) do
        unquote(simple_auth_context(e, :read))

        with unquote_splicing([
               with_entity_fetch(e),
               with_should_invocation(e, :read)
             ]) do
          {:ok, unquote(var(e))}
        end
      end
    end
  end

  defp get_by_key_fun_name(key) do
    fields = Enum.join(key[:fields], "_and_")
    String.to_atom("get_by_#{fields}")
  end

  defp unique_keys(e) do
    Enum.filter(e[:keys], fn k -> k[:unique] end)
  end

  defp get_by_key_resolver_funs(e) do
    e
    |> unique_keys()
    |> Enum.map(fn key ->
      fun_name = get_by_key_fun_name(key)

      args =
        Enum.map(key[:fields], fn name ->
          quote do
            args.unquote(var(name))
          end
        end)

      api_call =
        quote do
          {:ok, unquote(var(e))} <-
            unquote(e[:api_module]).unquote(fun_name)(unquote_splicing(args))
        end

      quote do
        def unquote(fun_name)(_, args, %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with unquote_splicing([
                 api_call,
                 with_should_invocation(e, :read)
               ]) do
            {:ok, unquote(var(e))}
          end
        end
      end
    end)
  end

  defp get_by_attribute_resolver_funs(e) do
    e[:attributes]
    |> Enum.filter(&unique?(&1))
    |> Enum.map(fn attr ->
      attr_name = attr[:name]
      fun_name = String.to_atom("get_by_#{attr[:name]}")

      quote do
        def unquote(fun_name)(
              _,
              args,
              %{context: context}
            ) do
          unquote(simple_auth_context(e, :read))

          with unquote_splicing([
                 with_entity_fetch(e, attr_name),
                 with_should_invocation(e, :read)
               ]) do
            {:ok, unquote(var(e))}
          end
        end
      end
    end)
  end

  defp attribute!(e, name) do
    attr = attribute?(e, name)

    unless attr do
      raise """
      no such attribute #{name} in entity #{e[:name]}.
        Existing attributes: #{e[:attributes] |> names() |> inspect()}"
      """
    end

    attr
  end

  defp unique_attribute!(e, name) do
    attr = attribute!(e, name)

    unless unique?(attr) do
      raise """
      attribute #{name} of entity #{e[:name]} is not marked as :unique: #{inspect(attr)}"
      """
    end

    attr
  end

  defp relation!(e, name) do
    rel = relation?(e, name)

    unless rel do
      raise """
      no such relation #{name} in entity #{e[:name]}.
        Existing relations: #{e[:relations] |> names() |> inspect()}"
      """
    end

    rel
  end

  defp inverse_relation!(schema, e, name) do
    rel = relation!(e, name)
    target = find_entity!(schema, rel[:target])

    case rel[:kind] do
      :has_many ->
        inverse_rels = Enum.filter(target[:relations], fn inv -> inv[:kind] == :belongs_to end)
        inverse_rel = Enum.find(inverse_rels, fn inv -> inv[:target] == e[:name] end)

        unless inverse_rel do
          raise """
            Could not find inverse for :has_many relation #{rel[:name]} of #{e[:name]} in
            #{inspect(inverse_rels)} of #{target[:name]}
          """
        end

        inverse_rel

      :belongs_to ->
        raise "Inverse for belongs_to -> has_many not implemented yet"
    end
  end

  defp relation?(e, name), do: field?(e[:relations], name)
  defp attribute?(e, name), do: field?(e[:attributes], name)
  defp field?(fields, name) when is_atom(name), do: Enum.find(fields, &(&1[:name] == name))
  defp field?(_, _), do: nil

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

  defp with_resolver_pagination_fun(funs) do
    [
      quote do
        @pagination_fields [:offset, :limit, :sort_by, :sort_direction]

        def context_with_pagination(args, context) do
          Enum.reduce(@pagination_fields, context, fn field, acc ->
            Map.put(acc, field, Map.get(args, field, nil))
          end)
        end
      end
      | funs
    ]
  end

  defp with_resolver_scope_results_fun(funs) do
    [
      quote do
        defp scope_results(mod, items, context) do
          entity = context.graphism.entity
          context = put_in(context, [:graphism, :action], :read)

          {:ok,
           Enum.filter(items, fn item ->
             context = Map.put(context, entity, item)
             mod.allow?(%{}, context)
           end)}
        end
      end
      | funs
    ]
  end

  defp with_resolver_auth_funs(funs, e, schema, hooks) do
    action_resolver_auth_funs =
      (e[:actions] ++ e[:custom_actions])
      |> Enum.reject(fn {name, _} -> name == :list end)
      |> Enum.map(fn {name, opts} ->
        resolver_auth_fun(name, opts, e, schema, hooks)
      end)

    funs ++
      ([
         action_resolver_auth_funs,
         resolver_list_auth_funs(e, schema, hooks)
       ]
       |> flat()
       |> without_nils())
  end

  defp resolver_list_auth_funs(e, schema, hooks) do
    e[:actions]
    |> Enum.filter(fn {action, _opts} -> action == :list end)
    |> Enum.flat_map(fn {_, opts} ->
      [
        resolver_list_all_auth_fun(e, opts, schema, hooks),
        resolver_list_by_parent_auth_funs(e, opts, schema, hooks)
      ]
    end)
  end

  defp simple_auth_context(e, action) do
    quote do
      context =
        context
        |> Map.drop([:__absinthe_plug__, :loader, :pubsub])
        |> Map.put(:graphism, %{
          entity: unquote(e[:name]),
          action: unquote(action),
          schema: unquote(e[:schema_module])
        })
    end
  end

  defp auth_mod_invocation(mod) do
    quote do
      case unquote(mod).allow?(args, context) do
        true ->
          true

        false ->
          {:error, :unauthorized}
      end
    end
  end

  defp allow_hook!(e, opts, action, hooks) do
    mod = opts[:allow] || hook(hooks, :allow, :default)

    unless mod do
      raise "missing :allow option in entity #{e[:name]} for action :#{action}, and no default authorization hook has been defined in the schema"
    end

    mod
  end

  defp scope_hook!(e, opts, action, hooks) do
    mod = opts[:scope] || hook(hooks, :allow, :default)

    unless mod do
      raise "missing :scope option in entity #{e[:name]} for action :#{action}, and no default authorization hook has been defined in the schema"
    end

    mod
  end

  defp resolver_list_all_auth_fun(e, opts, _schema, hooks) do
    mod = allow_hook!(e, opts, :list, hooks)

    quote do
      defp should_list?(args, context) do
        unquote(auth_mod_invocation(mod))
      end
    end
  end

  defp resolver_list_by_parent_auth_funs(e, opts, _schema, hooks) do
    mod = allow_hook!(e, opts, :list, hooks)

    e
    |> parent_relations()
    |> Enum.map(fn rel ->
      fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      ast =
        quote do
          defp unquote(fun_name)(unquote(var(rel)) = args, context) do
            unquote(auth_mod_invocation(mod))
          end
        end

      ast
    end)
  end

  defp auth_fun_entities_arg_names(e, action, opts) do
    cond do
      action == :update ->
        (e |> parent_relations() |> names()) ++ [e[:name]]

      action == :create ->
        e |> parent_relations() |> names()

      action == :read || action == :delete || has_id_arg?(opts) ->
        [e[:name]]

      true ->
        []
    end
  end

  defp resolver_auth_fun(action, opts, e, _schema, hooks) do
    mod = allow_hook!(e, opts, action, hooks)

    fun_name = String.to_atom("should_#{action}?")

    entities_var_names = auth_fun_entities_arg_names(e, action, opts)

    {empty_data, data_with_args, context_with_data} =
      case entities_var_names do
        [] ->
          {nil, nil, nil}

        _ ->
          {
            quote do
              data = %{}
            end,
            Enum.map(entities_var_names, fn e ->
              quote do
                data = Map.put(data, unquote(e), unquote(var(e)))
              end
            end),
            quote do
              context = Map.merge(context, data)
            end
          }
      end

    quote do
      def unquote(fun_name)(
            unquote_splicing(vars(entities_var_names)),
            args,
            context
          ) do
        (unquote_splicing(
           [
             empty_data,
             data_with_args,
             context_with_data,
             auth_mod_invocation(mod)
           ]
           |> flat()
           |> without_nils()
         ))
      end
    end
  end

  defp inline_relation_resolver_call(resolver_module, action) do
    quote do
      case unquote(resolver_module).unquote(action)(
             graphql.parent,
             child,
             graphql.resolution
           ) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, e} ->
          {:halt, {:error, e}}
      end
    end
  end

  defp with_resolver_inlined_relations_funs(funs, e, schema, _api_module) do
    (Enum.map([:create, :update], fn action ->
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
                          fun_name = String.to_atom("#{action}_inline_relation")

                          quote do
                            :ok <-
                              unquote(fun_name)(
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

                 children_rels =
                   quote do
                     Enum.reduce_while(children, :ok, fn child, _ ->
                       # populate the parent relation
                       # and delete to the child entity resolver
                       child =
                         Map.put(
                           child,
                           unquote(parent_rel[:name]),
                           unquote(Macro.var(e[:name], nil)).id
                         )

                       # if the child input contains an id,
                       # and we are updating, then we assume we want to update,
                       # if not we assume we want to create.
                       unquote(
                         case action do
                           :update ->
                             quote do
                               case Map.get(child, :id, nil) do
                                 nil ->
                                   unquote(inline_relation_resolver_call(resolver_module, :create))

                                 _ ->
                                   unquote(inline_relation_resolver_call(resolver_module, action))
                               end
                             end

                           _ ->
                             inline_relation_resolver_call(resolver_module, action)
                         end
                       )
                     end)
                   end

                 fun_name = String.to_atom("#{action}_inline_relation")

                 quote do
                   defp unquote(fun_name)(
                          unquote(Macro.var(e[:name], nil)),
                          args,
                          unquote(rel[:name]),
                          graphql
                        ) do
                     unquote(
                       quote do
                         case Map.get(args, unquote(rel[:name]), nil) do
                           nil ->
                             :ok

                           children ->
                             unquote(children_rels)
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

  defp resolver_list_fun(e, _schema, api_module, hooks) do
    action_opts = action_for(e, :list)
    scope_mod = scope_hook!(e, action_opts, :list, hooks)

    quote do
      def list(_, args, %{context: context}) do
        unquote(simple_auth_context(e, :list))

        with true <- should_list?(args, context),
             context <- context_with_pagination(args, context),
             {:ok, items} <- unquote(api_module).list(context) do
          scope_results(unquote(scope_mod), items, context)
        end
      end
    end
  end

  defp resolver_list_by_relation_funs(e, schema, api_module, hooks) do
    action_opts = action_for(e, :list)
    scope_mod = scope_hook!(e, action_opts, :list, hooks)

    e
    |> parent_relations()
    |> Enum.map(fn rel ->
      target = find_entity!(schema, rel[:target])
      fun_name = String.to_atom("list_by_#{rel[:name]}")
      auth_fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      quote do
        def unquote(fun_name)(_, args, %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with {:ok, unquote(var(rel))} <-
                 unquote(target[:api_module]).get_by_id(args.unquote(rel[:name])),
               true <- unquote(auth_fun_name)(unquote(var(rel)), context),
               context <- context_with_pagination(args, context),
               {:ok, items} <- unquote(api_module).unquote(fun_name)(unquote(var(rel)).id, context) do
            scope_results(unquote(scope_mod), items, context)
          end
        end
      end
    end)
  end

  defp with_resolver_list_funs(funs, e, schema, api_module, hooks) do
    with_entity_funs(funs, e, :list, fn ->
      [resolver_list_fun(e, schema, api_module, hooks)] ++
        resolver_list_by_relation_funs(e, schema, api_module, hooks)
    end)
  end

  defp resolver_aggregate_all_fun(e, _schema, api_module) do
    quote do
      def aggregate_all(_, args, %{context: context}) do
        unquote(simple_auth_context(e, :list))

        with true <- should_list?(args, context) do
          unquote(api_module).aggregate(context)
        end
      end
    end
  end

  defp resolver_aggregate_by_relation_funs(e, schema, api_module) do
    e
    |> parent_relations()
    |> Enum.map(fn rel ->
      target = find_entity!(schema, rel[:target])
      fun_name = String.to_atom("aggregate_by_#{rel[:name]}")
      auth_fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      quote do
        def unquote(fun_name)(_, args, %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with {:ok, unquote(var(rel))} <-
                 unquote(target[:api_module]).get_by_id(args.unquote(rel[:name])),
               true <- unquote(auth_fun_name)(unquote(var(rel)), context) do
            unquote(api_module).unquote(fun_name)(
              unquote(var(rel)).id,
              context
            )
          end
        end
      end
    end)
  end

  defp with_resolver_aggregate_funs(funs, e, schema, api_module) do
    with_entity_funs(funs, e, :list, fn ->
      [resolver_aggregate_all_fun(e, schema, api_module)] ++
        resolver_aggregate_by_relation_funs(e, schema, api_module)
    end)
  end

  defp inlined_children_for_action(e, action) do
    e[:relations]
    |> Enum.filter(fn rel ->
      :has_many == rel[:kind] &&
        inline_relation?(rel, action)
    end)
  end

  defp relations(e), do: e[:relations]

  defp parent_relations(e) do
    e
    |> relations()
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

  defp has_id_arg?(opts) do
    Enum.member?(opts[:args] || [], :id)
  end

  defp with_custom_action_entity_fetch(e, opts, _schema) do
    case has_id_arg?(opts) do
      true ->
        [
          quote do
            {:ok, unquote(var(e))} <-
              unquote(e[:api_module]).get_by_id(unquote(var(:args)).id)
          end,
          quote do
            args <- Map.put(args, unquote(e[:name]), unquote(var(e)))
          end,
          quote do
            args <- Map.drop(args, [:id])
          end
        ]

      false ->
        nil
    end
  end

  defp with_entity_fetch(e, attr) do
    fun_name = String.to_atom("get_by_#{attr}")

    args =
      ((e[:opts][:scope] || []) ++ [attr])
      |> Enum.map(fn arg ->
        quote do
          args.unquote(arg)
        end
      end)

    quote do
      {:ok, unquote(var(e))} <-
        unquote(e[:api_module]).unquote(fun_name)(unquote_splicing(args))
    end
  end

  # Builds a series of with clauses that fetch entity parent
  # dependencies required in order to either create or update
  # the entity
  defp with_parent_entities_fetch(e, schema, opts) do
    e
    |> parent_relations()
    |> with_parent_entities_fetch_from_rels(e, schema, opts)
  end

  defp with_computed_attributes(e, _schema, _opts) do
    e[:attributes]
    |> Enum.filter(&computed?/1)
    |> Enum.flat_map(fn attr ->
      cond do
        attr[:opts][:using] != nil ->
          mod = attr[:opts][:using]

          [
            quote do
              {:ok, unquote(var(attr))} <- unquote(mod).execute(context)
            end,
            quote do
              args <- Map.put(args, unquote(attr[:name]), unquote(var(attr)))
            end
          ]

        attr[:opts][:from_context] != nil ->
          from = attr[:opts][:from_context]

          [
            quote do
              unquote(var(attr)) <- get_in(context, unquote(from))
            end,
            quote do
              unquote(var(attr)) <- Map.get(unquote(var(attr)), :id)
            end,
            quote do
              args <- Map.put(args, unquote(attr[:name]), unquote(var(attr)))
            end
          ]

        true ->
          []
      end
    end)
  end

  defp with_custom_parent_entities_fetch(e, schema, opts) do
    opts[:args]
    |> Enum.map(&relation?(e, &1))
    |> without_nils()
    |> with_parent_entities_fetch_from_rels(e, schema, opts)
  end

  defp with_parent_entities_fetch_from_rels(rels, e, schema, opts \\ []) do
    api_module = e[:api_module]

    Enum.map(rels, fn rel ->
      case computed?(rel) do
        true ->
          cond do
            rel[:opts][:using] != nil ->
              mod = rel[:opts][:using]

              quote do
                {:ok, unquote(var(rel))} <- unquote(mod).execute(context)
              end

            rel[:opts][:from] != nil ->
              from = rel[:opts][:from]

              quote do
                unquote(var(rel)) <- unquote(api_module).relation(unquote(var(from)), unquote(rel[:name]))
              end

            rel[:opts][:from_context] != nil ->
              from = rel[:opts][:from_context]

              quote do
                unquote(var(rel)) <- get_in(context, unquote(from))
              end

            true ->
              raise "relation #{rel[:name]} of #{e[:name]} is computed but does not specify a :using or a :from option"
          end

        false ->
          target = find_entity!(schema, rel[:target])
          {arg_name, _, lookup_fun} = lookup_arg(schema, e, rel, opts[:action])

          quote do
            {:ok, unquote(var(rel))} <-
              unquote(
                case optional?(rel) do
                  false ->
                    case opts[:action] do
                      :update ->
                        quote do
                          case Map.get(unquote(var(:args)), unquote(arg_name), nil) do
                            nil ->
                              {:ok, unquote(api_module).relation(unquote(var(e)), unquote(rel[:name]))}

                            "" ->
                              {:ok, unquote(api_module).relation(unquote(var(e)), unquote(rel[:name]))}

                            key ->
                              unquote(target[:api_module]).unquote(lookup_fun)(key)
                          end
                        end

                      _ ->
                        quote do
                          unquote(target[:api_module]).unquote(lookup_fun)(unquote(var(:args)).unquote(arg_name))
                        end
                    end

                  true ->
                    quote do
                      case Map.get(unquote(var(:args)), unquote(arg_name), nil) do
                        nil ->
                          {:ok, nil}

                        "" ->
                          {:ok, nil}

                        key ->
                          unquote(target[:api_module]).unquote(lookup_fun)(key)
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

  defp with_custom_args_with_parents(e, opts, _schema) do
    opts[:args]
    |> Enum.map(&relation?(e, &1))
    |> without_nils()
    |> Enum.map(fn rel ->
      quote do
        args <- Map.put(args, unquote(rel[:name]), unquote(var(rel)))
      end
    end)
  end

  defp maybe_with_args_with_autogenerated_id!(e) do
    case client_ids?(e) do
      false ->
        quote do
          args <- Map.put(args, :id, Ecto.UUID.generate())
        end

      true ->
        nil
    end
  end

  defp maybe_with_with_autogenerated_id(_e, opts, _schema) do
    case has_id_arg?(opts) do
      false ->
        quote do
          args <-
            Map.put_new_lazy(args, :id, fn ->
              Ecto.UUID.generate()
            end)
        end

      true ->
        nil
    end
  end

  defp with_args_without_id() do
    quote do
      args <- Map.drop(args, [:id])
    end
  end

  defp with_should_invocation(e, action, opts \\ []) do
    fun_name = String.to_atom("should_#{action}?")

    quote do
      true <-
        unquote(fun_name)(
          unquote_splicing(auth_fun_entities_arg_names(e, action, opts) |> vars()),
          args,
          context
        )
    end
  end

  defp resolver_fun_args_for_action(e, action) do
    inlined_children = inlined_children_for_action(e, action)

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
  end

  defp with_resolver_create_fun(funs, e, schema, api_module, opts) do
    with_entity_funs(funs, e, :create, fn ->
      inlined_children = inlined_children_for_action(e, :create)

      {parent_var, resolution_var} = resolver_fun_args_for_action(e, :create)

      quote do
        def create(unquote(parent_var), unquote(var(:args)), unquote(resolution_var)) do
          unquote(simple_auth_context(e, :create))

          with unquote_splicing(
                 [
                   with_parent_entities_fetch(e, schema, action: :create),
                   with_args_without_parents(e),
                   maybe_with_args_with_autogenerated_id!(e),
                   with_computed_attributes(e, schema, opts),
                   with_should_invocation(e, :create)
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

  defp with_resolver_update_fun(funs, e, schema, api_module, opts) do
    with_entity_funs(funs, e, :update, fn ->
      inlined_children = inlined_children_for_action(e, :update)

      {parent_var, resolution_var} = resolver_fun_args_for_action(e, :update)

      ast =
        quote do
          def update(unquote(parent_var), unquote(var(:args)), unquote(resolution_var)) do
            unquote(simple_auth_context(e, :update))

            with unquote_splicing(
                   [
                     with_entity_fetch(e),
                     with_parent_entities_fetch(e, schema, action: :update),
                     with_args_without_parents(e),
                     with_args_without_id(),
                     with_should_invocation(e, :update)
                   ]
                   |> flat()
                   |> without_nils()
                 ) do
              unquote(
                case inlined_children do
                  [] ->
                    quote do
                      unquote(api_module).update(
                        unquote_splicing((e |> parent_relations() |> names() |> vars()) ++ [var(e), var(:args)])
                      )
                    end

                  children ->
                    quote do
                      {children_args, args} =
                        Map.split(
                          args,
                          unquote(names(children))
                        )

                      unquote(opts[:repo]).transaction(fn ->
                        with {:ok, unquote(var(e))} <-
                               unquote(api_module).update(
                                 unquote_splicing(
                                   (e |> parent_relations() |> names() |> vars()) ++
                                     [var(e), var(:args)]
                                 )
                               ),
                             :ok <-
                               update_inline_relations(
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

      ast
    end)
  end

  defp with_resolver_delete_fun(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :delete, fn ->
      quote do
        def delete(_parent, unquote(var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :delete))

          with unquote_splicing(
                 [
                   with_entity_fetch(e),
                   with_should_invocation(e, :delete)
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

  defp resolver_custom_fun(e, action, opts, api_module, schema) do
    opts = Keyword.put(opts, :action, action)

    quote do
      def unquote(action)(_, args, %{context: context}) do
        unquote(simple_auth_context(e, action))

        with unquote_splicing(
               [
                 with_custom_action_entity_fetch(e, opts, schema),
                 with_custom_parent_entities_fetch(e, schema, opts),
                 with_custom_args_with_parents(e, opts, schema),
                 maybe_with_with_autogenerated_id(e, opts, schema),
                 with_should_invocation(e, action, opts)
               ]
               |> flat()
               |> without_nils()
             ) do
          unquote(api_module).unquote(action)(args)
        end
      end
    end
  end

  defp resolver_module(e, schema, opts) do
    api_module = e[:api_module]
    hooks = Keyword.fetch!(opts, :hooks)

    resolver_funs =
      []
      |> with_resolver_pagination_fun()
      |> with_resolver_scope_results_fun()
      |> with_resolver_auth_funs(e, schema, hooks)
      |> with_resolver_inlined_relations_funs(e, schema, api_module)
      |> with_resolver_list_funs(e, schema, api_module, hooks)
      |> with_resolver_aggregate_funs(e, schema, api_module)
      |> with_resolver_read_funs(e, schema, api_module)
      |> with_resolver_create_fun(e, schema, api_module, opts)
      |> with_resolver_update_fun(e, schema, api_module, opts)
      |> with_resolver_delete_fun(e, schema, api_module)
      |> with_resolver_custom_funs(e, schema, api_module)
      |> List.flatten()

    quote do
      defmodule unquote(e[:resolver_module]) do
        (unquote_splicing(resolver_funs))
      end
    end
  end

  defp api_module(e, schema, hooks, opts) do
    case virtual?(e) do
      false ->
        schema_module = e[:schema_module]
        repo_module = opts[:repo]

        api_funs =
          []
          |> with_api_convenience_functions(e, schema_module, repo_module)
          |> with_query_preload_fun(e, schema)
          |> with_optional_query_pagination_fun(e, schema_module)
          |> with_api_list_funs(e, schema_module, repo_module, schema, hooks)
          |> with_api_aggregate_funs(e, schema_module, repo_module, schema, hooks)
          |> with_api_read_funs(e, schema_module, repo_module, schema)
          |> with_api_create_fun(e, schema_module, repo_module, schema)
          |> with_api_batch_create_fun(e, schema_module, repo_module, schema)
          |> with_api_update_fun(e, schema_module, repo_module, schema)
          |> with_api_delete_fun(e, schema_module, repo_module, schema)
          |> with_api_custom_funs(e)
          |> List.flatten()

        quote do
          defmodule unquote(e[:api_module]) do
            import Ecto.Query

            @default_offset 0
            @default_limit 20

            (unquote_splicing(api_funs))
          end
        end

      true ->
        actions = e[:actions]
        custom_actions = e[:custom_actions]

        e =
          e
          |> Keyword.put(:custom_actions, Keyword.merge(custom_actions, actions))
          |> Keyword.put(:actions, [])

        api_funs =
          []
          |> with_api_custom_funs(e)
          |> List.flatten()

        quote do
          defmodule unquote(e[:api_module]) do
            (unquote_splicing(api_funs))
          end
        end
    end
  end

  defp entity_aggregate_query_opts(_e, _schema) do
    []
  end

  defp with_query_preload_fun(funs, e, _schema) do
    preloads = preloads(e)

    fun =
      case preloads do
        [] ->
          quote do
            defp maybe_with_preloads(query), do: {:ok, query}
          end

        preloads ->
          quote do
            defp maybe_with_preloads(query) do
              {:ok, from(i in query, preload: unquote(preloads))}
            end
          end
      end

    [fun | funs]
  end

  defp with_optional_query_pagination_fun(funs, e, schema_module) do
    {default_sort_by, default_sort_direction} =
      case e[:opts][:sort] do
        :none -> {nil, nil}
        nil -> {:inserted_at, :asc}
        other -> other
      end

    [
      quote do
        defp maybe_paginate(query, context) do
          with {:ok, query} <- maybe_sort(query, context) do
            {:ok,
             query
             |> maybe_limit(context)
             |> maybe_offset(context)}
          end
        end

        defp maybe_sort(query, context) do
          sort_by = context[:sort_by] || unquote(default_sort_by)
          sort_direction = context[:sort_direction] || unquote(default_sort_direction)

          maybe_sort(query, sort_by, sort_direction)
        end

        defp cast_sort_direction("asc"), do: {:ok, :asc}
        defp cast_sort_direction("desc"), do: {:ok, :desc}
        defp cast_sort_direction(:asc), do: {:ok, :asc}
        defp cast_sort_direction(:desc), do: {:ok, :desc}
        defp cast_sort_direction(_other), do: {:error, :invalid_sort_direction}

        defp maybe_sort(query, nil, _), do: {:ok, query}

        defp maybe_sort(query, field, direction) do
          with {:ok, sort_direction} <- cast_sort_direction(direction),
               {:ok, sort_column} <- sort_column(field) do
            opts = [{sort_direction, sort_column}]
            {:ok, from(i in subquery(query), order_by: ^opts)}
          end
        end

        defp sort_column(field) do
          case unquote(schema_module).field_spec(field) do
            {:ok, _, sort_column} -> {:ok, sort_column}
            {:ok, :belongs_to, _, _, sort_column} -> {:ok, sort_column}
            _ -> {:error, :invalid_sort_by}
          end
        end

        defp maybe_limit(query, context) do
          case Map.get(context, :limit) do
            nil -> query
            limit -> limit(query, ^limit)
          end
        end

        defp maybe_offset(query, context) do
          case Map.get(context, :offset) do
            nil -> query
            offset -> offset(query, ^offset)
          end
        end
      end
      | funs
    ]
  end

  defp with_api_convenience_functions(funs, _e, _schema, repo_module) do
    [
      quote do
        defp maybe_id(nil), do: nil
        defp maybe_id(%{id: id}), do: id

        def relation(parent, child) do
          case Map.get(parent, child) do
            %{id: _} = rel ->
              rel

            nil ->
              nil

            _ ->
              parent
              |> unquote(repo_module).preload(child)
              |> Map.get(child)
          end
        end
      end
      | funs
    ]
  end

  defp with_api_list_funs(funs, e, schema_module, repo_module, _schema, hooks) do
    action_opts = action_for(e, :list)
    scope_mod = scope_hook!(e, action_opts, :list, hooks)

    [
      quote do
        def list(context \\ %{}) do
          query = from(unquote(var(e)) in unquote(schema_module))

          with query <- unquote(scope_mod).scope(query, context),
               {:ok, query} <- maybe_paginate(query, context),
               {:ok, query} <- maybe_with_preloads(query) do
            {:ok, unquote(repo_module).all(query)}
          end
        end
      end
      | e[:relations]
        |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
        |> Enum.map(fn rel ->
          quote do
            def unquote(String.to_atom("list_by_#{rel[:name]}"))(id, context \\ %{}) do
              query =
                from(unquote(var(rel)) in unquote(schema_module))
                |> where([q], q.unquote(String.to_atom("#{rel[:name]}_id")) == ^id)

              with query <- unquote(scope_mod).scope(query, context),
                   {:ok, query} <- maybe_paginate(query, context),
                   {:ok, query} <- maybe_with_preloads(query) do
                {:ok, unquote(repo_module).all(query)}
              end
            end
          end
        end)
    ] ++ funs
  end

  defp with_api_aggregate_funs(funs, e, schema_module, repo_module, schema, hooks) do
    query_opts = entity_aggregate_query_opts(e, schema)

    action_opts = action_for(e, :list)
    scope_mod = scope_hook!(e, action_opts, :list, hooks)

    [
      quote do
        def aggregate(context \\ %{}) do
          query =
            from(
              unquote(var(e)) in unquote(schema_module),
              unquote(query_opts)
            )

          with query <- unquote(scope_mod).scope(query, context) do
            {:ok, %{count: unquote(repo_module).aggregate(query, :count)}}
          end
        end
      end
      | e[:relations]
        |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
        |> Enum.map(fn rel ->
          name = String.to_atom("aggregate_by_#{rel[:name]}")

          quote do
            def unquote(name)(id, context \\ %{}) do
              query =
                from(
                  unquote(var(rel)) in unquote(schema_module),
                  unquote(query_opts)
                )
                |> where([q], q.unquote(String.to_atom("#{rel[:name]}_id")) == ^id)

              with query <- unquote(scope_mod).scope(query, context) do
                {:ok, %{count: unquote(repo_module).aggregate(query, :count)}}
              end
            end
          end
        end)
    ] ++ funs
  end

  defp child_preloads(e) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :has_many && rel[:opts][:preloaded] end)
    |> Enum.reduce([], fn rel, acc ->
      Keyword.put(acc, rel[:name], rel[:opts][:preload] || [])
    end)
    |> Enum.reverse()
  end

  defp parent_preloads(e) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to && rel[:opts][:preloaded] end)
    |> Enum.reduce([], fn rel, acc ->
      Keyword.put(acc, rel[:name], rel[:opts][:preload] || [])
    end)
    |> Enum.reverse()
  end

  defp preloads(e), do: parent_preloads(e) ++ child_preloads(e)

  defp get_by_id_api_fun(e, schema_module, repo_module, _schema) do
    preloads = preloads(e)

    quote do
      def get_by_id(id, opts \\ []) do
        preloads =
          case opts[:skip_preloads] do
            true -> []
            _ -> unquote(preloads) ++ (opts[:preload] || [])
          end

        case unquote(schema_module)
             |> unquote(repo_module).get(id)
             |> unquote(repo_module).preload(preloads) do
          nil ->
            {:error, :not_found}

          e ->
            {:ok, e}
        end
      end
    end
  end

  defp get_by_id_bang_api_fun(schema_module) do
    quote do
      def get_by_id!(id, opts \\ []) do
        case get_by_id(id, opts) do
          {:ok, e} ->
            e

          {:error, :not_found} ->
            raise "No row with id #{id} of type #{unquote(schema_module)} was found"
        end
      end
    end
  end

  defp get_by_key_api_funs(e, schema_module, repo_module, _schema) do
    preloads = preloads(e)

    e
    |> unique_keys()
    |> Enum.map(fn key ->
      fun_name = get_by_key_fun_name(key)

      args =
        Enum.map(key[:fields], fn name ->
          quote do
            unquote(var(name))
          end
        end)

      filters =
        Enum.map(key[:fields], fn field ->
          case relation?(e, field) do
            nil ->
              quote do
                {unquote(field), unquote(var(field))}
              end

            _ ->
              quote do
                {unquote(String.to_atom("#{field}_id")), unquote(var(field))}
              end
          end
        end)

      quote do
        def unquote(fun_name)(unquote_splicing(args), opts \\ []) do
          preloads =
            case opts[:skip_preloads] do
              true -> []
              _ -> unquote(preloads) ++ (opts[:preload] || [])
            end

          filters = [unquote_splicing(filters)]

          case unquote(schema_module)
               |> unquote(repo_module).get_by(filters)
               |> unquote(repo_module).preload(preloads) do
            nil ->
              {:error, :not_found}

            e ->
              {:ok, e}
          end
        end
      end
    end)
  end

  defp get_by_unique_attrs_api_funs(e, schema_module, repo_module, _schema) do
    preloads = preloads(e)

    e[:attributes]
    |> Enum.filter(&unique?(&1))
    |> Enum.map(fn attr ->
      scope_args =
        (e[:opts][:scope] || [])
        |> Enum.map(fn rel ->
          var(rel)
        end)

      args =
        scope_args ++
          [
            var(attr)
          ]

      quote do
        def unquote(String.to_atom("get_by_#{attr[:name]}"))(unquote_splicing(args), opts \\ []) do
          value =
            case is_atom(unquote(var(attr))) do
              true ->
                "#{unquote(var(attr))}"

              false ->
                unquote(var(attr))
            end

          filters = [
            unquote_splicing(
              ((e[:opts][:scope] || [])
               |> Enum.map(fn arg ->
                 column_name = String.to_atom("#{arg}_id")

                 quote do
                   {unquote(column_name), unquote(var(arg))}
                 end
               end)) ++
                [
                  quote do
                    {unquote(attr[:name]), value}
                  end
                ]
            )
          ]

          preloads =
            case opts[:skip_preloads] do
              true -> []
              _ -> unquote(preloads) ++ (opts[:preload] || [])
            end

          case unquote(schema_module)
               |> unquote(repo_module).get_by(filters)
               |> unquote(repo_module).preload(preloads) do
            nil ->
              {:error, :not_found}

            e ->
              {:ok, e}
          end
        end
      end
    end)
  end

  defp with_api_read_funs(funs, e, schema_module, repo_module, schema) do
    [
      get_by_id_api_fun(e, schema_module, repo_module, schema),
      get_by_id_bang_api_fun(schema_module)
    ] ++
      get_by_key_api_funs(e, schema_module, repo_module, schema) ++
      get_by_unique_attrs_api_funs(e, schema_module, repo_module, schema) ++ funs
  end

  defp hook_call(e, mod, :before, :update) do
    quote do
      {:ok, attrs} <- unquote(mod).execute(unquote(var(e)), attrs)
    end
  end

  defp hook_call(_, mod, :before, _) do
    quote do
      {:ok, attrs} <- unquote(mod).execute(attrs)
    end
  end

  defp hook_call(e, mod, :after, _) do
    quote do
      {:ok, unquote(var(e))} <- unquote(mod).execute(unquote(var(e)))
    end
  end

  defp hooks(nil), do: []
  defp hooks(mod) when is_atom(mod), do: [mod]
  defp hooks(mods) when is_list(mods), do: mods

  defp hooks(e, phase, action) do
    opts =
      e[:actions][action] ||
        e[:custom_actions][action]

    opts[phase]
    |> hooks()
    |> Enum.map(&hook_call(e, &1, phase, action))
  end

  def debug_ast(ast, condition \\ true) do
    if condition do
      ast
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.puts()
    end

    ast
  end

  defp attrs_with_parent_relations(e) do
    e
    |> parent_relations()
    |> Enum.flat_map(fn rel ->
      rel_key = rel[:name]
      rel_id_key = String.to_atom("#{rel_key}_id")

      [
        quote do
          attrs <- Map.put(attrs, unquote(rel_key), unquote(var(rel)))
        end,
        quote do
          attrs <- Map.put(attrs, unquote(rel_id_key), maybe_id(unquote(var(rel))))
        end
      ]
    end)
  end

  defp with_api_create_fun(funs, e, schema_module, repo_module, _schema) do
    parent_relations = attrs_with_parent_relations(e)

    insert =
      quote do
        {:ok, unquote(var(e))} <-
          %unquote(schema_module){}
          |> unquote(schema_module).changeset(attrs)
          |> unquote(repo_module).insert(opts)
      end

    refetch =
      quote do
        {:ok, unquote(var(e))} <- get_by_id(unquote(var(e)).id, opts)
      end

    before_hooks = hooks(e, :before, :create)
    after_hooks = hooks(e, :after, :create)

    fun =
      quote do
        def create(
              unquote_splicing(
                e
                |> parent_relations()
                |> vars()
              ),
              attrs,
              opts \\ []
            ) do
          unquote(repo_module).transaction(fn ->
            with unquote_splicing(
                   [
                     parent_relations,
                     before_hooks,
                     insert,
                     refetch,
                     after_hooks
                   ]
                   |> flat()
                   |> without_nils()
                 ) do
              unquote(var(e))
            else
              {:error, e} ->
                unquote(repo_module).rollback(e)
            end
          end)
        end
      end

    [fun | funs]
  end

  defp with_api_batch_create_fun(funs, _e, schema_module, repo_module, _schema) do
    fun =
      quote do
        def batch_create(items, opts \\ []) do
          case unquote(repo_module).insert_all(unquote(schema_module), items, opts) do
            {count, _} -> {:ok, count}
            other -> {:error, other}
          end
        end
      end

    [fun | funs]
  end

  defp with_api_update_fun(funs, e, schema_module, repo_module, _schema) do
    parent_relations = attrs_with_parent_relations(e)

    update =
      quote do
        {:ok, unquote(var(e))} <-
          unquote(var(e))
          |> unquote(schema_module).changeset(attrs)
          |> unquote(repo_module).update()
      end

    refetch =
      quote do
        {:ok, unquote(var(e))} <- get_by_id(unquote(var(e)).id, opts)
      end

    before_hooks = hooks(e, :before, :update)
    after_hooks = hooks(e, :after, :update)

    fun =
      quote do
        def update(
              unquote_splicing(
                e
                |> parent_relations()
                |> vars()
              ),
              unquote(var(e)),
              attrs,
              opts \\ []
            ) do
          unquote(repo_module).transaction(fn ->
            with unquote_splicing(
                   [
                     parent_relations,
                     before_hooks,
                     update,
                     refetch,
                     after_hooks
                   ]
                   |> flat()
                   |> without_nils()
                 ) do
              unquote(var(e))
            else
              {:error, e} ->
                unquote(repo_module).rollback(e)
            end
          end)
        end
      end

    [fun | funs]
  end

  defp with_api_delete_fun(funs, e, schema_module, repo_module, _schema) do
    before_hooks = hooks(e, :before, :delete)
    after_hooks = hooks(e, :after, :delete)

    delete =
      quote do
        {:ok, attrs} <-
          attrs
          |> unquote(schema_module).delete_changeset()
          |> unquote(repo_module).delete()
      end

    [
      quote do
        def delete(%unquote(schema_module){} = attrs) do
          unquote(repo_module).transaction(fn ->
            with unquote_splicing(
                   [
                     before_hooks,
                     delete,
                     after_hooks
                   ]
                   |> flat()
                   |> without_nils()
                 ) do
              attrs
            else
              {:error, e} ->
                unquote(repo_module).rollback(e)
            end
          end)
        end
      end
      | funs
    ]
  end

  defp with_api_custom_funs(funs, e) do
    Enum.map(e[:custom_actions], fn {action, opts} ->
      api_custom_fun(e, action, opts)
    end) ++ funs
  end

  defp api_custom_fun(e, action, opts) do
    using_mod = opts[:using]

    unless using_mod do
      raise "custom action #{action} of #{e[:name]} does not define a :using option"
    end

    quote do
      def unquote(action)(attrs) do
        unquote(using_mod).execute(attrs)
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

  defp boolean?(attr) do
    attr[:kind] == :boolean
  end

  defp enum?(attr) do
    attr[:opts][:one_of] != nil
  end

  defp attr_graphql_type(attr) do
    attr[:opts][:one_of] || attr[:kind]
  end

  defp with_default?(attr) do
    Keyword.has_key?(attr[:opts], :default)
  end

  defp graphql_nullable_type?(attr) do
    (optional?(attr) && !non_empty?(attr)) || (with_default?(attr) && !enum?(attr) && !boolean?(attr))
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
      kind = attr_graphql_type(attr)

      kind =
        case attr[:opts][:allow] do
          nil ->
            case graphql_nullable_type?(attr) || opts[:mode] == :input || opts[:mode] == :update do
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
      # inside input types, we don't want to include children
      # relations. Also we might want to skip certain entities depdencing
      # on the context
      Enum.member?(
        opts[:skip] || [],
        rel[:target]
      ) ||
        ((computed?(rel) || rel[:kind] == :has_many) &&
           (opts[:mode] == :input || opts[:mode] == :update_input))
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
        :update_input ->
          quote do
            field(
              unquote(rel[:name]),
              :id
            )
          end

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
          case virtual?(e) do
            false ->
              quote do
                field(
                  unquote(rel[:name]),
                  unquote(kind),
                  resolve: dataloader(unquote(opts[:caller]).Dataloader.Repo)
                )
              end

            true ->
              quote do
                field(
                  unquote(rel[:name]),
                  unquote(kind)
                )
              end
          end
      end
    end)
  end

  @timestamp_fields [:inserted_at, :updated_at]

  defp graphql_timestamp_fields() do
    @timestamp_fields
    |> Enum.map(fn field ->
      quote do
        field(unquote(field), non_null(:datetime))
      end
    end)
  end

  defp graphql_object(e, schema, opts) do
    quote do
      object unquote(e[:name]) do
        (unquote_splicing(
           graphql_attribute_fields(e, schema, opts) ++
             graphql_timestamp_fields() ++
             graphql_relation_fields(e, schema, opts)
         ))
      end
    end
  end

  defp graphql_enum(enum, values) do
    quote do
      enum unquote(enum) do
        (unquote_splicing(
           Enum.map(values, fn value ->
             quote do
               value(unquote(value), as: unquote("#{value}"))
             end
           end)
         ))
      end
    end
  end

  @readonly_actions [:read, :list]

  defp readonly_action?(name) do
    Enum.member?(@readonly_actions, name)
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
                 graphql_query_find_by_unique_fields(e, schema),
                 graphql_query_find_by_keys(e, schema)
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
                 graphql_query_aggregate_all(e, schema),
                 graphql_query_find_by_parent_queries(e, schema),
                 graphql_query_aggregate_by_parent_queries(e, schema)
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
        arg(:limit, :integer)
        arg(:offset, :integer)
        arg(:sort_by, :string)
        arg(:sort_direction, :asc_desc)
        resolve(&unquote(e[:resolver_module]).list/3)
      end
    end
  end

  defp graphql_query_aggregate_all(e, _schema) do
    quote do
      @desc "Aggregate all " <> unquote("#{e[:plural_display_name]}")
      field :aggregate_all, non_null(:aggregate) do
        resolve(&unquote(e[:resolver_module]).aggregate_all/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field :by_id,
            non_null(unquote(e[:name])) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).get_by_id/3)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(&unique?(&1))
    |> Enum.map(fn attr ->
      kind = attr_graphql_type(attr)
      description = "Find a single #{e[:display_name]} given its unique #{attr[:name]}"

      {scope_args, description} =
        case e[:opts][:scope] do
          nil ->
            {[], description}

          rels ->
            {Enum.map(rels, fn name ->
               quote do
                 arg(unquote(name), non_null(:id))
               end
             end), "#{description}. This query is scoped by #{rels |> Enum.join(",")}."}
        end

      args =
        scope_args ++
          [
            quote do
              arg(unquote(attr[:name]), non_null(unquote(kind)))
            end
          ]

      quote do
        @desc unquote(description)
        field unquote(String.to_atom("by_#{attr[:name]}")),
              non_null(unquote(e[:name])) do
          unquote_splicing(args)

          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("get_by_#{attr[:name]}")) / 3))
        end
      end
    end)
  end

  defp graphql_query_find_by_keys(e, _schema) do
    e
    |> unique_keys()
    |> Enum.map(fn key ->
      fields = key[:fields] |> Enum.join(" and ")
      description = "Find a single #{e[:display_name]} given its #{fields}"
      resolver_fun = get_by_key_fun_name(key)
      query_name = resolver_fun |> to_string() |> String.replace("get_", "") |> String.to_atom()

      args =
        Enum.map(key[:fields], fn name ->
          case entity_attribute_or_relation(e, name) do
            {:attribute, attr} ->
              kind = attr_graphql_type(attr)

              quote do
                arg(unquote(name), non_null(unquote(kind)))
              end

            {:relation, _} ->
              quote do
                arg(unquote(name), non_null(:id))
              end
          end
        end)

      quote do
        @desc unquote(description)
        field unquote(query_name), non_null(unquote(e[:name])) do
          unquote_splicing(args)
          resolve(&(unquote(e[:resolver_module]).unquote(resolver_fun) / 3))
        end
      end
    end)
  end

  defp graphql_query_find_by_parent_queries(e, _schema) do
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
          arg(:limit, :integer)
          arg(:offset, :integer)
          arg(:sort_by, :string)
          arg(:sort_direction, :asc_desc)
          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("list_by_#{rel[:name]}")) / 3))
        end
      end
    end)
  end

  defp graphql_query_aggregate_by_parent_queries(e, _schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
    |> Enum.map(fn rel ->
      name = String.to_atom("aggregate_by_#{rel[:name]}")
      description = "Aggregate all #{e[:plural_display_name]} by their parent #{rel[:target]}"

      quote do
        @desc unquote(description)
        field unquote(name), non_null(:aggregate) do
          arg(unquote(rel[:name]), non_null(:id))
          resolve(&(unquote(e[:resolver_module]).unquote(name) / 3))
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
             graphql_attribute_fields(target, schema, mode: :input, skip: [:id]) ++
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

  defp graphql_update_input_types(e, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :has_many == rel[:kind] && inline_relation?(rel, :update) end)
    |> Enum.map(fn rel ->
      target = find_entity!(schema, rel[:target])
      input_type = String.to_atom("#{target[:name]}_update_input")

      quote do
        input_object unquote(input_type) do
          (unquote_splicing(
             graphql_attribute_fields(target, schema, mode: :update) ++
               graphql_relation_fields(target, schema,
                 mode: :update_input,
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

  defp immutable?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :immutable)
  end

  defp non_empty?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :non_empty)
  end

  def graphql_resolver(e, action) do
    quote do
      &(unquote(e[:resolver_module]).unquote(action) / 3)
    end
  end

  defp inline_relation?(rel, action) do
    Enum.member?(rel[:opts][:inline] || [], action)
  end

  defp mutation_arg_from_attribute(_, attr) do
    kind = attr_graphql_type(attr)

    quote do
      arg(
        unquote(attr[:name]),
        unquote(
          case optional?(attr) || with_default?(attr) do
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
  end

  defp lookup_arg(schema, e, rel, action) do
    case get_in(e, [:actions, action, :lookup, rel[:name]]) do
      nil ->
        {rel[:name], :id, :get_by_id}

      key ->
        target = find_entity!(schema, rel[:target])
        attr = unique_attribute!(target, key)
        lookup_arg_name = String.to_atom("#{rel[:target]}_#{attr[:name]}")
        {lookup_arg_name, attr[:kind], String.to_atom("get_by_#{attr[:name]}")}
    end
  end

  defp mutation_arg_from_relation(schema, e, rel, action) do
    {name, kind, _} = lookup_arg(schema, e, rel, action)

    case optional?(rel) do
      false ->
        quote do
          arg(unquote(name), non_null(unquote(kind)))
        end

      true ->
        quote do
          arg(unquote(name), unquote(kind))
        end
    end
  end

  defp mutation_arg_from_inlined_relation(_e, rel) do
    input_type = String.to_atom("#{rel[:target]}_input")

    quote do
      arg(unquote(rel[:name]), list_of(non_null(unquote(input_type))))
    end
  end

  defp maybe_client_generated_id_arg(e) do
    case client_ids?(e) do
      false ->
        []

      true ->
        [
          quote do
            arg(:id, non_null(:id))
          end
        ]
    end
  end

  defp graphql_create_mutation(e, schema) do
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
          maybe_client_generated_id_arg(e) ++
            (e[:attributes]
             |> Enum.reject(fn attr -> attr[:name] == :id end)
             |> Enum.reject(&computed?(&1))
             |> Enum.map(&mutation_arg_from_attribute(e, &1))) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
             |> Enum.reject(&computed?(&1))
             |> Enum.map(&mutation_arg_from_relation(schema, e, &1, :create))) ++
            (e[:relations]
             |> Enum.filter(fn rel ->
               :has_many == rel[:kind] && inline_relation?(rel, :create)
             end)
             |> Enum.map(&mutation_arg_from_inlined_relation(e, &1)))
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
               attr[:name] == :id || computed?(attr) || immutable?(attr)
             end)
             |> Enum.map(fn attr ->
               kind = attr_graphql_type(attr)

               quote do
                 arg(
                   unquote(attr[:name]),
                   unquote(kind)
                 )
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
             |> Enum.reject(&(computed?(&1) || immutable?(&1)))
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), :id)
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel ->
               :has_many == rel[:kind] && inline_relation?(rel, :update)
             end)
             |> Enum.map(fn rel ->
               input_type = String.to_atom("#{rel[:target]}_update_input")

               quote do
                 arg(unquote(rel[:name]), list_of(non_null(unquote(input_type))))
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

  defp entity_relation(e, name) do
    Enum.find(e[:relations], fn attr ->
      name == attr[:name]
    end)
  end

  defp entity_attribute_or_relation(e, name) do
    case entity_attribute(e, name) do
      nil ->
        case entity_relation(e, name) do
          nil ->
            raise "No entity or relation #{name} in entity #{e[:name]}"

          rel ->
            {:relation, rel}
        end

      attr ->
        {:attribute, attr}
    end
  end

  defp graphql_custom_mutation(e, action, opts, _schema) do
    args = opts[:args]
    produces = opts[:produces]
    desc = opts[:desc] || "Custom action"

    quote do
      @desc unquote(desc)
      field unquote(action),
            unquote(
              case produces do
                {:list, produces} ->
                  quote do
                    list_of(unquote(produces))
                  end

                produces ->
                  quote do
                    non_null(unquote(produces))
                  end
              end
            ) do
        (unquote_splicing(
           Enum.map(args, fn
             {arg, {kind, :optional}} ->
               quote do
                 arg(unquote(arg), unquote(kind))
               end

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
                     attr_graphql_type(attr)
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

  defp attributes_from({:__block__, _, attrs}) do
    attrs
    |> Enum.map(&attribute/1)
    |> Enum.map(&maybe_computed/1)
    |> without_nils()
  end

  defp attributes_from({:attribute, _, attr}) do
    [attribute(attr)]
  end

  defp attributes_from(other) do
    without_nils([attribute(other)])
  end

  defp attribute({:attribute, _, opts}), do: attribute(opts)
  defp attribute([name, kind]), do: attribute([name, kind, []])
  defp attribute([name, kind, opts]), do: [name: name, kind: kind, opts: opts]

  defp attribute({:unique, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:unique | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  defp attribute({:maybe, _, [opts]}) do
    attribute({:optional, nil, [opts]})
  end

  defp attribute({:immutable, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:immutable | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  defp attribute({:non_empty, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:non_empty | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  defp attribute({:virtual, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:virtual | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  defp attribute({:optional, _, [{:belongs_to, _, _}]}), do: nil

  defp attribute({:optional, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:optional | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  defp attribute({:computed, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:computed | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  defp attribute({:private, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:private | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  defp attribute({:string, _, [name]}), do: attribute([name, :string])
  defp attribute({:text, _, [name]}), do: attribute([name, :string, [store: :text]])
  defp attribute({:integer, _, [name]}), do: attribute([name, :integer])
  defp attribute({:boolean, _, [name]}), do: attribute([name, :boolean])
  defp attribute({:float, _, [name]}), do: attribute([name, :float])
  defp attribute({:datetime, _, [name]}), do: attribute([name, :datetime])
  defp attribute({:date, _, [name]}), do: attribute([name, :date])
  defp attribute({:decimal, _, [name]}), do: attribute([name, :decimal])
  defp attribute({:upload, _, [name]}), do: attribute([name, :upload, [modifiers: [:virtual]]])
  defp attribute({:json, _, [name]}), do: attribute([name, :json, [schema: Graphism.Type.Ecto.Jsonb, store: :map]])

  defp attribute({kind, _, [attr, opts]}) do
    with attr when attr != nil <- attribute({kind, nil, [attr]}) do
      opts = Keyword.merge(attr[:opts], opts)
      Keyword.put(attr, :opts, opts)
    end
  end

  defp attribute(_), do: nil

  defp keys_from({:__block__, _, items}) do
    items
    |> Enum.map(&key_from/1)
    |> without_nils()
  end

  defp keys_from(_), do: []

  defp key_from({:key, _, [fields]}) do
    [name: key_name(fields), fields: fields, unique: true]
  end

  defp key_from({:key, _, [fields, opts]}) do
    [name: key_name(fields), fields: fields, unique: Keyword.get(opts, :unique, true)]
  end

  defp key_from(_), do: nil

  defp key_name(fields), do: fields |> Enum.map(&to_string/1) |> Enum.join("_") |> String.to_atom()

  defp maybe_add_id_attribute(attrs) do
    if attrs |> Enum.filter(fn attr -> attr[:name] == :id end) |> Enum.empty?() do
      [attribute([:id, :id]) | attrs]
    else
      attrs
    end
  end

  defp relations_from({:__block__, _, rels}) do
    rels
    |> Enum.map(&relation_from/1)
    |> without_nils()
    |> Enum.map(&maybe_computed/1)
    |> Enum.map(&maybe_preloaded/1)
  end

  defp relations_from(_) do
    []
  end

  defp relation_from({:maybe, _, [opts]}),
    do: relation_from({:optional, nil, [opts]})

  defp relation_from({:optional, _, [{kind, _, _} = opts]}) when kind in [:belongs_to, :has_many] do
    rel = relation_from(opts)
    modifiers = get_in(rel, [:opts, :modifiers]) || []
    put_in(rel, [:opts, :modifiers], [:optional | modifiers])
  end

  defp relation_from({:immutable, _, [opts]}) do
    with rel when rel != nil <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []
      put_in(rel, [:opts, :modifiers], [:immutable | modifiers])
    end
  end

  defp relation_from({:non_empty, _, [opts]}) do
    with rel when rel != nil <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []
      put_in(rel, [:opts, :modifiers], [:non_empty | modifiers])
    end
  end

  defp relation_from({:has_many, _, [name]}),
    do: [name: name, kind: :has_many, opts: [], plural: name]

  defp relation_from({:has_many, _, [name, opts]}),
    do: [name: name, kind: :has_many, opts: opts, plural: name]

  defp relation_from({:belongs_to, _, [name]}), do: [name: name, kind: :belongs_to, opts: []]

  defp relation_from({:belongs_to, _, [name, opts]}),
    do: [name: name, kind: :belongs_to, opts: opts]

  defp relation_from({:preloaded, _, [opts]}) do
    rel = relation_from(opts)
    unless rel, do: raise("Unsupported relation #{inspect(opts)} for preloaded modifier")
    opts = rel[:opts] || []
    opts = Keyword.put(opts, :preloaded, true)
    Keyword.put(rel, :opts, opts)
  end

  defp relation_from(_), do: nil

  defp maybe_computed(field) do
    from_opt = get_in(field, [:opts, :from]) || get_in(field, [:opts, :from_context])

    case from_opt do
      nil ->
        field

      _ ->
        modifiers = get_in(field, [:opts, :modifiers]) || []

        case Enum.member?(modifiers, :computed) do
          true ->
            field

          false ->
            put_in(field, [:opts, :modifiers], [:computed | modifiers])
        end
    end
  end

  defp maybe_preloaded(rel) do
    case rel[:opts][:preload] do
      nil -> rel
      _ -> put_in(rel, [:opts, :preloaded], true)
    end
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

  defp with_action_produces(opts, entity_name) do
    if !built_in_action?(opts[:name]) && !opts[:produces] do
      Keyword.put(opts, :produces, entity_name)
    else
      opts
    end
  end

  defp with_action_args(opts) do
    if opts[:produces] && !opts[:args] do
      Keyword.put(opts, :args, [:id])
    else
      args = opts[:args]
      Keyword.put(opts, :args, args)
    end
  end

  defp actions_from({:__block__, _, actions}, entity_name) do
    actions
    |> Enum.reduce([], fn action, acc ->
      case action_from(action, entity_name) do
        nil ->
          acc

        action ->
          Keyword.put(acc, action[:name], action[:opts])
      end
    end)
    |> without_nils()
  end

  defp actions_from(_, _), do: []

  defp action_from({:action, _, [name, opts]}, entity_name),
    do: action_from(name, opts, entity_name)

  defp action_from({:action, _, [name]}, entity_name), do: action_from(name, [], entity_name)
  defp action_from(_, _), do: nil

  defp action_from(name, opts, entity_name) do
    opts =
      opts
      |> with_action_hook(:using)
      |> with_action_hook(:before)
      |> with_action_hook(:after)
      |> with_action_produces(entity_name)
      |> with_action_args()
      |> with_action_hook(:allow)
      |> with_action_hook(:scope)

    [name: name, opts: opts]
  end
end
