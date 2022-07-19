defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias Graphism.{
    Api,
    Entity
  }

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
        |> Entity.resolve_schema()

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

      default_allow_hook = Entity.hook(hooks, :allow, :default)

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

      schema = Enum.reverse(schema)

      schema
      |> Enum.each(fn e ->
        if Enum.empty?(e[:attributes]) and
             Enum.empty?(e[:relations]) do
          raise "Entity #{e[:name]} is empty"
        end
      end)

      schema_empty_modules = Graphism.Schema.empty_modules(schema)

      schema_modules =
        schema
        |> Enum.reject(&Entity.virtual?(&1))
        |> Enum.map(fn e ->
          Graphism.Schema.schema_module(e, schema, caller: __CALLER__)
        end)

      api_modules =
        Enum.map(schema, fn e ->
          Graphism.Api.api_module(e, schema, hooks, repo: repo, caller: __CALLER__)
        end)

      resolver_modules =
        Enum.map(schema, fn e ->
          Graphism.Resolver.resolver_module(e, schema,
            repo: repo,
            hooks: hooks,
            caller: __CALLER__
          )
        end)

      graphql_dataloader_queries = Graphism.Graphql.dataloader_queries(schema)
      graphql_fields_auth = Graphism.Graphql.fields_auth_module(schema, default_allow_hook)
      graphql_enums = Graphism.Graphql.enums(enums)
      graphql_objects = Graphism.Graphql.objects(schema, caller: __CALLER__.module)
      graphql_self_resolver = Graphism.Graphql.self_resolver()
      graphql_aggregate_type = Graphism.Graphql.aggregate_type()
      graphql_entities_queries = Graphism.Graphql.entities_queries(schema)
      graphql_entities_mutations = Graphism.Graphql.entities_mutations(schema)
      graphql_input_types = Graphism.Graphql.input_types(schema)
      graphql_queries = Graphism.Graphql.queries(schema)
      graphql_mutations = Graphism.Graphql.mutations(schema)

      List.flatten([
        enums_fun,
        schema_fun,
        schema_empty_modules,
        schema_modules,
        api_modules,
        resolver_modules,
        graphql_dataloader_queries,
        graphql_fields_auth,
        graphql_enums,
        graphql_input_types,
        graphql_objects,
        graphql_self_resolver,
        graphql_aggregate_type,
        graphql_entities_queries,
        graphql_entities_mutations,
        graphql_queries,
        graphql_mutations
      ])
    end
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

  defmacro entity(name, opts \\ [], do: block) do
    caller_module = __CALLER__.module

    attrs =
      Entity.attributes_from(block)
      |> Entity.maybe_add_id_attribute()

    rels = Entity.relations_from(block)
    actions = Entity.actions_from(block, name)
    lists = Entity.lists_from(block, name)
    keys = Entity.keys_from(block)

    {actions, custom_actions} = Entity.split_actions(actions)
    custom_actions = custom_actions ++ lists

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
      |> Entity.with_plural()
      |> Entity.with_table_name()
      |> Entity.with_schema_module(caller_module)
      |> Entity.with_api_module(caller_module)
      |> Entity.with_resolver_module(caller_module)
      |> Entity.maybe_with_scope()

    Module.put_attribute(__CALLER__.module, :schema, entity)
    block
  end

  defmacro attribute(name, type, opts \\ []) do
    Entity.validate_attribute_name!(name)
    Entity.validate_attribute_type!(type)
    Entity.validate_attribute_opts!(opts)
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

  defmacro list(_name, _opts \\ []) do
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
end
