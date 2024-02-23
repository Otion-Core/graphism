defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias Graphism.{
    Entity,
    Policy
  }

  require Logger

  defmacro __using__(opts \\ []) do
    Code.compiler_options(ignore_module_conflict: true)

    repo = Keyword.fetch!(opts, :repo)
    auth = opts[:auth]
    styles = opts[:styles] || [:graphql]

    Module.register_attribute(__CALLER__.module, :data,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :scope,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :default_policy,
      accumulate: false,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :role,
      accumulate: false,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :schema_imports,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :repo,
      accumulate: false,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :auth,
      accumulate: false,
      persist: true
    )

    Module.put_attribute(__CALLER__.module, :repo, repo)
    Module.put_attribute(__CALLER__.module, :auth, auth)
    Module.put_attribute(__CALLER__.module, :styles, styles)

    middleware =
      Enum.map(opts[:middleware] || [], fn {:__aliases__, _, mod} ->
        Module.concat(mod)
      end)

    quote do
      import unquote(__MODULE__), only: :macros
      @before_compile unquote(__MODULE__)

      unquote do
        if Enum.member?(styles, :graphql) do
          quote do
            use Absinthe.Schema
            import_types(Absinthe.Type.Custom)
            import_types(Absinthe.Plug.Types)
            import_types(Graphism.Type.Graphql.Json)
            @middleware unquote(middleware)

            def context(ctx), do: Map.put(ctx, :loader, __MODULE__.Dataloader.new())

            def plugins do
              @middleware ++ [__MODULE__.Dataloader.Absinthe] ++ Absinthe.Plugin.defaults()
            end

            def middleware(middleware, _field, _object) do
              middleware ++ [Graphism.ErrorMiddleware]
            end
          end
        end
      end
    end
  end

  defmacro __before_compile__(_) do
    caller_module = __CALLER__.module

    repo =
      caller_module
      |> Module.get_attribute(:repo)

    auth_module =
      caller_module
      |> Module.get_attribute(:auth, caller_module)

    styles =
      caller_module
      |> Module.get_attribute(:styles)

    schema =
      caller_module
      |> Module.get_attribute(:schema)
      |> Entity.resolve_schema()

    scopes =
      caller_module
      |> Module.get_attribute(:scope)
      |> index_by(:name)
      |> Policy.resolve_scopes()

    default_policy = Module.get_attribute(caller_module, :default_policy)

    role = Module.get_attribute(caller_module, :role)

    data = Module.get_attribute(caller_module, :data)

    enums =
      data
      |> Enum.filter(fn {_, values} -> is_list(values) end)

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

    schema = Enum.reverse(schema)

    Enum.each(schema, fn e ->
      Entity.ensure_not_empty!(e)
      Entity.ensure_action_scopes!(e, scopes)
    end)

    enums_fun =
      quote do
        def enums() do
          unquote(enums)
        end
      end

    schema_fun =
      quote do
        def schema do
          unquote(Macro.escape(schema))
        end
      end

    schema_empty_modules = Graphism.Schema.empty_modules(schema)

    schema_modules =
      schema
      |> Enum.reject(&Entity.virtual?(&1))
      |> Enum.map(fn e ->
        Graphism.Schema.schema_module(e, schema)
      end)

    auth_funs =
      if auth_module == caller_module do
        Graphism.Auth.auth_funs(schema, scopes, default_policy, role)
      else
        nil
      end

    api_modules =
      Enum.map(schema, fn e ->
        Graphism.Api.api_module(e, schema, repo, auth_module)
      end)

    dataloader_module = Graphism.Dataloader.dataloader_module(caller_module)
    schema_filter_fun = Graphism.Querying.filter_fun()
    schema_evaluate_fun = Graphism.Querying.evaluate_fun(repo)
    schema_compare_fun = Graphism.Querying.compare_fun()

    rest_modules =
      if Enum.member?(styles, :rest) do
        openapi_module = Graphism.Openapi.spec_module(schema, caller_module)
        redocui_module = Graphism.Openapi.redocui_module(caller_module)
        rest_router_module = Graphism.Rest.router_module(schema, caller_module)
        rest_handler_modules = Graphism.Rest.handler_modules(schema, repo, caller_module)
        rest_helper_modules = Graphism.Rest.helper_modules(auth_module)
        json_encoder_modules = Graphism.Encoder.json_modules(schema)

        [
          openapi_module,
          redocui_module,
          rest_helper_modules,
          rest_handler_modules,
          rest_router_module,
          json_encoder_modules
        ]
      else
        []
      end

    graphql_modules =
      if Enum.member?(styles, :graphql) do
        graphql_resolver_modules =
          Enum.map(schema, fn e ->
            Graphism.Resolver.resolver_module(e, schema, auth_module, repo)
          end)

        graphql_dataloader_middleware = Graphism.Dataloader.absinthe_middleware(caller_module)
        graphql_enums = Graphism.Graphql.enums(enums)
        graphql_objects = Graphism.Graphql.objects(schema)
        graphql_self_resolver = Graphism.Graphql.self_resolver()
        graphql_aggregate_type = Graphism.Graphql.aggregate_type()
        graphql_entities_queries = Graphism.Graphql.entities_queries(schema)
        graphql_entities_mutations = Graphism.Graphql.entities_mutations(schema)
        graphql_input_types = Graphism.Graphql.input_types(schema)
        graphql_queries = Graphism.Graphql.queries(schema)
        graphql_mutations = Graphism.Graphql.mutations(schema)

        [
          graphql_resolver_modules,
          graphql_dataloader_middleware,
          graphql_enums,
          graphql_objects,
          graphql_self_resolver,
          graphql_aggregate_type,
          graphql_entities_queries,
          graphql_entities_mutations,
          graphql_input_types,
          graphql_queries,
          graphql_mutations
        ]
      else
        []
      end

    List.flatten(
      [
        enums_fun,
        schema_fun,
        schema_empty_modules,
        schema_modules,
        auth_funs,
        api_modules,
        dataloader_module,
        schema_filter_fun,
        schema_evaluate_fun,
        schema_compare_fun
      ] ++ graphql_modules ++ rest_modules
    )
  end

  defp index_by(items, key) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      Map.put(acc, Map.fetch!(item, key), item)
    end)
  end

  defmacro import_schema({:__aliases__, _, module}) do
    Module.put_attribute(__CALLER__.module, :schema_imports, Module.concat(module))
  end

  defmacro auth({:__aliases__, _, module}) do
    Module.put_attribute(__CALLER__.module, :auth, module)
  end

  defmacro entity(name, opts \\ [], do: block) do
    caller_module = __CALLER__.module

    schema_module =
      Module.concat([
        caller_module,
        Inflex.camelize(name)
      ])

    attrs =
      Entity.attributes_from(block)
      |> Entity.maybe_add_id_attribute()
      |> Entity.maybe_add_slug_attribute(schema_module, block)

    entity_policies = Entity.entity_policies(block)

    rels = Entity.relations_from(block)

    actions =
      block
      |> Entity.actions_from(name)
      |> Entity.actions_with_policies(name, entity_policies)

    lists = Entity.lists_from(block, name)
    keys = Entity.keys_from(block)

    {actions, custom_actions} = Entity.split_actions(opts, actions)
    custom_actions = custom_actions ++ lists

    entity =
      [
        name: name,
        schema_module: schema_module,
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
      |> Entity.with_api_module(caller_module)
      |> Entity.with_resolver_module(caller_module)
      |> Entity.with_handler_module(caller_module)
      |> Entity.with_json_encoder_module(caller_module)
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

  defmacro custom(_name) do
  end

  defmacro action(_name, _opts, _block) do
  end

  defmacro list(_name, _opts \\ []) do
  end

  defmacro list(_name, _opts, _block) do
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

  defmacro bigint(_name, _opts \\ []) do
  end

  defmacro float(_name, _opts \\ []) do
  end

  defmacro boolean(_name, _opts \\ []) do
  end

  defmacro datetime(_name, _opts \\ []) do
  end

  defmacro date(_name, _opts \\ []) do
  end

  defmacro time(_name, _opts \\ []) do
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

  defmacro allow(_block) do
  end

  defmacro read(_role, _block) do
  end

  defmacro write(_role, _block \\ nil) do
  end

  defmacro scope(name, block) do
    scope = Policy.scope_from(name, block)
    Module.put_attribute(__CALLER__.module, :scope, scope)
  end

  defmacro scope(_name) do
  end

  defmacro deny do
    Module.put_attribute(__CALLER__.module, :default_policy, :deny)
  end

  defmacro allow do
    Module.put_attribute(__CALLER__.module, :default_policy, :allow)
  end

  defmacro role(expr) do
    Module.put_attribute(__CALLER__.module, :role, expr)
  end

  defmacro slug(_field) do
  end
end
