defmodule Graphism.Rest do
  @moduledoc "Generates a REST api"

  alias Graphism.{Ast, Entity, Openapi, Route}

  def helper_modules(auth_module) do
    quote do
      defmodule RouterHelper do
        import Plug.Conn
        @json "application/json"

        def send_json(conn, body, status \\ 200) do
          conn
          |> put_resp_content_type(@json)
          |> send_resp(status, Jason.encode!(body))
        end

        def send_error(conn, %Ecto.Changeset{errors: errors}) do
          reason =
            Enum.map(errors, fn {field, {message, _}} ->
              %{field: field, detail: message}
            end)

          send_error(conn, reason)
        end

        def send_error(conn, reason) do
          send_json(conn, %{reason: reason(reason)}, status(reason))
        end

        def cast_param(conn, name, kind, default \\ :invalid) do
          value = conn.params[name]

          cast(value, kind, default)
        end

        def lookup(conn, param, api, :required) do
          with {:ok, id} <- cast_param(conn, param, :id) do
            api.get_by_id(id)
          end
        end

        def lookup(conn, param, api, :optional) do
          lookup_or_default(conn, param, api, fn -> nil end)
        end

        def lookup(conn, param, api, {:relation, api2, item, rel}) do
          lookup_or_default(conn, param, api, fn ->
            api2.relation(item, rel)
          end)
        end

        defp lookup_or_default(conn, param, api, default_fn) do
          case conn.params[param] do
            nil ->
              {:ok, default_fn.()}

            "" ->
              {:ok, default_fn.()}

            value ->
              with {:ok, id} <- cast(value, :id) do
                api.get_by_id(id)
              end
          end
        end

        def lookup_relation(api, entity, relation) do
          entity
          |> api.relation(relation)
          |> maybe_error(:not_found)
        end

        def lookup_context(context, path) do
          context
          |> get_in(path)
          |> maybe_error(:missing_context)
        end

        defp maybe_error(nil, reason), do: {:error, reason}
        defp maybe_error(value, _), do: {:ok, value}

        def with_pagination(conn) do
          with {:ok, offset} <- cast_param(conn, "offset", :integer, 0),
               {:ok, limit} <- cast_param(conn, "limit", :integer, 20),
               {:ok, sort_by} <- cast_param(conn, "sort_by", :string, nil),
               {:ok, sort_direction} <- cast_param(conn, "sort_direction", :string, "asc") do
            {:ok,
             conn
             |> assign(:offset, offset)
             |> assign(:limit, limit)
             |> assign(:sort_by, sort_by)
             |> assign(:sort_direction, sort_direction)}
          end
        end

        def with_item(assigns, item) do
          Map.put(assigns, assigns.graphism.entity, item)
        end

        def allowed?(assigns, args \\ nil) do
          if unquote(auth_module).allow?(args, assigns) do
            :ok
          else
            {:error, :unauthorized}
          end
        end

        defp cast(nil, _, :invalid), do: {:error, :invalid}
        defp cast(nil, _, :continue), do: {:error, :continue}
        defp cast(nil, _, default), do: {:ok, default}
        defp cast(v, kind, _), do: cast(v, kind)

        defp cast(v, :id) do
          with :error <- Ecto.UUID.cast(v) do
            {:error, :invalid}
          end
        end

        defp cast(v, :integer) do
          case Integer.parse(v) do
            {v, ""} -> {:ok, v}
            :error -> {:error, :invalid}
          end
        end

        defp cast(v, :string) when is_binary(v), do: {:ok, v}
        defp cast(json, :json) when is_map(json), do: {:ok, json}

        def as(result, arg, args \\ %{})
        def as({:ok, v}, arg, args), do: {:ok, Map.put(args, arg, v)}
        def as({:error, :continue}, _, args), do: {:ok, args}
        def as({:error, _} = error, _, _), do: error

        defp reason(r) when is_atom(r), do: r |> to_string() |> reason()
        defp reason(r) when is_binary(r), do: [%{detail: r}]
        defp reason(r) when is_list(r), do: r

        defp status(:not_found), do: 404
        defp status(:invalid), do: 400
        defp status(:unauthorized), do: 401
        defp status(:conflict), do: 409
        defp status([%{detail: "has already been taken"}]), do: 409
        defp status(_), do: 500
      end
    end
  end

  def router_module(schema, caller_module) do
    telemetry_event_prefix =
      caller_module
      |> to_string()
      |> String.downcase()
      |> String.replace("elixir", "")
      |> String.replace("schema", "")
      |> String.split(".")
      |> Enum.filter(fn s -> String.length(s) > 0 end)
      |> Enum.map(&String.to_atom/1)
      |> Kernel.++([:router])

    quote do
      defmodule Router do
        use Plug.Router
        import RouterHelper

        plug(:match)
        plug(Plug.Telemetry, event_prefix: unquote(telemetry_event_prefix))

        plug(Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

        plug(:dispatch)

        unquote_splicing(routes(schema))

        get("/openapi.json", to: unquote(Openapi.module_name(caller_module)))

        match _ do
          send_json(unquote(Ast.var(:conn)), %{reason: :no_route}, 404)
        end
      end
    end
  end

  def handler_modules(schema, repo_module, caller_module) do
    opts = [caller_module: caller_module, schema: schema, repo: repo_module]

    Enum.flat_map(schema, fn e ->
      standard_actions_handler_modules(e, opts) ++
        aggregation_handler_modules(e, opts) ++
        list_children_handler_modules(e, opts) ++
        list_by_non_unique_key_handler_modules(e, opts) ++
        list_by_custom_queries_handler_modules(e, opts) ++
        read_by_unique_key_modules(e, opts) ++
        custom_actions_handler_modules(e, opts)
    end)
  end

  defp standard_actions_handler_modules(e, opts) do
    [
      list_handler_module(e, opts),
      read_handler_module(e, opts),
      create_handler_module(e, opts),
      update_handler_module(e, opts),
      delete_handler_module(e, opts)
    ]
  end

  defp aggregation_handler_modules(e, opts) do
    [
      aggregate_all_handler_module(e, opts)
    ]
  end

  defp read_by_unique_key_modules(e, opts) do
    e
    |> Entity.unique_keys_and_attributes()
    |> Enum.map(&read_by_unique_key_module(e, &1, opts))
  end

  defp list_children_handler_modules(e, opts) do
    e
    |> Entity.relations()
    |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
    |> Enum.flat_map(fn rel ->
      [
        list_children_handler_module(e, rel, opts),
        aggregate_children_handler_module(e, rel, opts)
      ]
    end)
  end

  defp list_by_non_unique_key_handler_modules(e, opts) do
    e
    |> Entity.non_unique_keys()
    |> Enum.flat_map(fn key ->
      [
        list_by_non_unique_key_handler_module(e, key, opts),
        aggregate_by_non_unique_key_handler_module(e, key, opts)
      ]
    end)
  end

  defp list_by_custom_queries_handler_modules(e, opts) do
    e
    |> Entity.custom_queries()
    |> Enum.flat_map(fn {name, action_opts} ->
      [
        list_by_custom_query_handler_module(e, name, action_opts, opts),
        aggregate_by_custom_query_handler_module(e, name, action_opts, opts)
      ]
    end)
  end

  defp custom_actions_handler_modules(e, opts) do
    e
    |> Entity.custom_mutations()
    |> Enum.map(fn {name, action_opts} ->
      custom_action_handler_module(e, name, action_opts, opts)
    end)
  end

  defp list_handler_module(e, opts) do
    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               {:ok, conn} <- with_pagination(conn),
               {:ok, items} <- unquote(e[:api_module]).list(conn.assigns) do
            send_json(conn, items)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :list, body, opts)
  end

  defp aggregate_all_handler_module(e, opts) do
    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               {:ok, item} <- unquote(e[:api_module]).aggregate(conn.assigns) do
            send_json(conn, item)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :aggregate, body, opts)
  end

  defp list_children_handler_module(e, rel, opts) do
    schema = Keyword.fetch!(opts, :schema)
    belongs_to = Entity.inverse_relation!(schema, e, rel[:name])
    target = Entity.find_entity!(schema, rel[:target])
    action = list_children_action(rel)
    api_fun_name = Entity.list_by_parent_fun_name(belongs_to)

    opts =
      opts
      |> Keyword.put(:auth_action, :list)
      |> Keyword.put(:auth_entity, rel[:target])

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               {:ok, id} <- cast_param(conn, "id", :id),
               {:ok, _} <- unquote(e[:api_module]).get_by_id(id),
               {:ok, conn} <- with_pagination(conn),
               {:ok, items} <-
                 unquote(target[:api_module]).unquote(api_fun_name)(id, conn.assigns) do
            send_json(conn, items)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp aggregate_children_handler_module(e, rel, opts) do
    schema = Keyword.fetch!(opts, :schema)
    belongs_to = Entity.inverse_relation!(schema, e, rel[:name])
    target = Entity.find_entity!(schema, rel[:target])
    action = aggregate_children_action(rel)
    api_fun_name = Entity.aggregate_by_parent_fun_name(belongs_to)

    opts =
      opts
      |> Keyword.put(:auth_action, :list)
      |> Keyword.put(:auth_entity, rel[:target])

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               {:ok, id} <- cast_param(conn, "id", :id),
               {:ok, _} <- unquote(e[:api_module]).get_by_id(id),
               {:ok, result} <-
                 unquote(target[:api_module]).unquote(api_fun_name)(id, conn.assigns) do
            send_json(conn, result)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp list_by_non_unique_key_handler_module(e, key, opts) do
    action = list_by_non_unique_key_action(key)
    api_fun_name = Entity.list_by_key_fun_name(key)

    opts =
      opts
      |> Keyword.put(:auth_action, :list)
      |> Keyword.put(:auth_entity, e[:name])

    field_var_names = Ast.vars(key[:fields])
    field_vars = cast_key_values_from_conn(key, e)

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               unquote_splicing(field_vars),
               {:ok, conn} <- with_pagination(conn),
               {:ok, items} <-
                 unquote(e[:api_module]).unquote(api_fun_name)(
                   unquote_splicing(field_var_names),
                   conn.assigns
                 ) do
            send_json(conn, items)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp aggregate_by_non_unique_key_handler_module(e, key, opts) do
    action = aggregate_by_non_unique_key_action(key)
    api_fun_name = Entity.aggregate_by_key_fun_name(key)

    opts =
      opts
      |> Keyword.put(:auth_action, :list)
      |> Keyword.put(:auth_entity, e[:name])

    field_var_names = Ast.vars(key[:fields])
    field_vars = cast_key_values_from_conn(key, e)

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               unquote_splicing(field_vars),
               {:ok, result} <-
                 unquote(e[:api_module]).unquote(api_fun_name)(
                   unquote_splicing(field_var_names),
                   conn.assigns
                 ) do
            send_json(conn, result)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp list_by_custom_query_handler_module(e, action, action_opts, opts) do
    {args_vars, args} = custom_action_args(e, action_opts, opts)

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               unquote_splicing(args_vars),
               args <- %{},
               unquote_splicing(args),
               {:ok, conn} <- with_pagination(conn),
               {:ok, items} <-
                 unquote(e[:api_module]).unquote(action)(args, conn.assigns) do
            send_json(conn, items)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp aggregate_by_custom_query_handler_module(e, action, action_opts, opts) do
    opts = Keyword.put(opts, :auth_action, action)
    action = aggregate_by_custom_query_action(action)

    {args_vars, args} = custom_action_args(e, action_opts, opts)

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               unquote_splicing(args_vars),
               args <- %{},
               unquote_splicing(args),
               {:ok, result} <-
                 unquote(e[:api_module]).unquote(action)(args, conn.assigns) do
            send_json(conn, result)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp cast_key_values_from_conn(key, e) do
    key[:fields]
    |> Enum.map(fn f ->
      case Entity.attribute_or_relation(e, f) do
        {:attribute, attr} -> {f, attr[:kind]}
        {:relation, _} -> {f, :id}
      end
    end)
    |> Enum.map(fn {name, kind} ->
      quote do
        {:ok, unquote(Ast.var(name))} <- cast_param(conn, unquote(to_string(name)), unquote(kind))
      end
    end)
  end

  defp read_handler_module(e, opts) do
    body =
      quote do
        def handle(conn, _opts) do
          with {:ok, item} <- lookup(conn, "id", unquote(e[:api_module]), :required),
               :ok <- conn.assigns |> with_item(item) |> allowed?() do
            send_json(conn, item)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :read, body, opts)
  end

  defp read_by_unique_key_module(e, key, opts) do
    action = read_by_unique_key_action(key)
    api_fun = Graphism.Entity.get_by_key_fun_name(key)

    vars = Enum.map(key[:fields], fn f -> Ast.var(f) end)

    cast_params =
      Enum.map(key[:fields], fn f ->
        param = to_string(f)

        kind =
          case Entity.attribute_or_relation(e, f) do
            {:attribute, attr} -> attr[:kind]
            {:relation, _} -> :id
          end

        quote do
          {:ok, unquote(Ast.var(f))} <- cast_param(conn, unquote(param), unquote(kind))
        end
      end)

    body =
      quote do
        def handle(conn, _opts) do
          with unquote_splicing(cast_params),
               {:ok, item} <- unquote(e[:api_module]).unquote(api_fun)(unquote_splicing(vars)),
               :ok <- conn.assigns |> with_item(item) |> allowed?() do
            send_json(conn, item)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    opts = Keyword.put(opts, :auth_action, :read)

    handler_module(e, action, body, opts)
  end

  defp handler_id_arg(e, _opts) do
    case Entity.client_ids?(e) do
      true ->
        quote do
          {:ok, args} <- conn |> cast_param("id", :id) |> as(:id)
        end

      false ->
        quote do
          args <- %{id: Ecto.UUID.generate()}
        end
    end
  end

  defp handler_attribute_args(e, opts) do
    e[:attributes]
    |> Enum.reject(&Entity.id?/1)
    |> Enum.reject(&Entity.computed?/1)
    |> Enum.map(&handler_attribute_cast_param(&1, opts))
  end

  defp handler_attribute_cast_param(attr, opts) do
    name = attr[:name]
    kind = attr[:kind]
    mode = Keyword.get(opts, :mode, :create)

    default =
      case {mode, Entity.optional?(attr)} do
        {:create, true} -> nil
        {:create, false} -> :invalid
        {:update, true} -> nil
        {:update, false} -> :continue
      end

    quote do
      {:ok, args} <-
        conn
        |> cast_param(unquote(to_string(name)), unquote(kind), unquote(default))
        |> as(unquote(name), args)
    end
  end

  defp handler_parent_arg_vars(e) do
    e |> Entity.parent_relations() |> Entity.names() |> Ast.vars()
  end

  defp handler_parent_args(e, opts) do
    handler_non_computed_parent_args(e, opts) ++
      handler_computed_parent_args(e, opts)
  end

  defp handler_non_computed_parent_args(e, opts) do
    schema = Keyword.fetch!(opts, :schema)
    mode = Keyword.get(opts, :mode, :create)

    e
    |> Entity.parent_relations()
    |> Enum.reject(&Entity.computed?/1)
    |> Enum.map(fn rel ->
      name = rel[:name]
      target = Entity.find_entity!(schema, rel[:target])

      case mode do
        :create ->
          default = if Entity.optional?(rel), do: :optional, else: :invalid

          quote do
            {:ok, unquote(Ast.var(name))} <-
              lookup(
                conn,
                unquote(to_string(name)),
                unquote(target[:api_module]),
                unquote(default)
              )
          end

        :update ->
          quote do
            {:ok, unquote(Ast.var(name))} <-
              lookup(
                conn,
                unquote(to_string(name)),
                unquote(target[:api_module]),
                {:relation, unquote(e[:api_module]), unquote(Ast.var(e)), unquote(name)}
              )
          end
      end
    end)
  end

  defp handler_computed_parent_args(e, opts) do
    handler_computed_parents_from_context_args(e, opts) ++
      handler_computed_ancestor_args(e, opts) ++
      handler_computed_parents_using_hook_args(e, opts)
  end

  defp handler_computed_ancestor_args(e, opts) do
    schema = Keyword.fetch!(opts, :schema)

    e
    |> Entity.parent_relations()
    |> Enum.filter(&Entity.computed?/1)
    |> Enum.filter(&Entity.ancestor?/1)
    |> Enum.map(fn rel ->
      name = rel[:name]

      [parent_rel_name, ancestor_rel_name] = Entity.computed_relation_path(rel)

      parent_rel = Entity.relation!(e, parent_rel_name)
      api_module = Entity.find_entity!(schema, parent_rel[:target])[:api_module]

      quote do
        {:ok, unquote(Ast.var(name))} <-
          lookup_relation(
            unquote(api_module),
            unquote(Ast.var(parent_rel_name)),
            unquote(ancestor_rel_name)
          )
      end
    end)
  end

  defp handler_computed_parents_from_context_args(e, _opts) do
    e
    |> Entity.parent_relations()
    |> Enum.filter(fn rel -> rel[:opts][:from_context] end)
    |> Enum.map(fn rel ->
      name = rel[:name]
      from = rel[:opts][:from_context]

      quote do
        {:ok, unquote(Ast.var(name))} <- lookup_context(conn.assigns, unquote(from))
      end
    end)
  end

  defp handler_computed_parents_using_hook_args(e, _opts) do
    e
    |> Entity.parent_relations()
    |> Enum.filter(fn rel -> rel[:opts][:using] end)
    |> Enum.map(fn rel ->
      name = rel[:name]
      mod = rel[:opts][:using]

      quote do
        {:ok, unquote(Ast.var(name))} <- unquote(mod).execute(conn.assigns)
      end
    end)
  end

  defp create_handler_module(e, opts) do
    args = handler_attribute_args(e, opts) ++ handler_parent_args(e, opts)
    args = [handler_id_arg(e, opts) | args]

    body =
      quote do
        def handle(conn, _opts) do
          with unquote_splicing(args),
               :ok <- allowed?(conn.assigns, args),
               {:ok, item} <-
                 unquote(e[:api_module]).create(
                   unquote_splicing(handler_parent_arg_vars(e)),
                   args
                 ) do
            send_json(conn, item, 201)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :create, body, opts)
  end

  defp update_handler_module(e, opts) do
    opts = Keyword.put(opts, :mode, :update)
    args = handler_attribute_args(e, opts) ++ handler_parent_args(e, opts)

    body =
      quote do
        def handle(conn, _opts) do
          with {:ok, unquote(Ast.var(e))} <-
                 lookup(conn, "id", unquote(e[:api_module]), :required),
               args <- %{},
               unquote_splicing(args),
               :ok <- conn.assigns |> with_item(unquote(Ast.var(e))) |> allowed?(args),
               {:ok, unquote(Ast.var(e))} <-
                 unquote(e[:api_module]).update(
                   unquote_splicing(handler_parent_arg_vars(e)),
                   unquote(Ast.var(e)),
                   args
                 ) do
            send_json(conn, unquote(Ast.var(e)))
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :update, body, opts)
  end

  defp delete_handler_module(e, opts) do
    body =
      quote do
        def handle(conn, _opts) do
          with {:ok, id} <- cast_param(conn, "id", :id),
               {:ok, item} <- unquote(e[:api_module]).get_by_id(id),
               :ok <- conn.assigns |> with_item(item) |> allowed?(),
               {:ok, _} <- unquote(e[:api_module]).delete(item) do
            send_json(conn, %{})
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, :delete, body, opts)
  end

  defp custom_action_handler_module(e, action, action_opts, opts) do
    {args_vars, args} = custom_action_args(e, action_opts, opts)

    body =
      quote do
        def handle(conn, _opts) do
          with :ok <- allowed?(conn.assigns),
               unquote_splicing(args_vars),
               args <- %{},
               unquote_splicing(args),
               {:ok, result} <-
                 unquote(e[:api_module]).unquote(action)(args, conn.assigns) do
            send_json(conn, result)
          else
            {:error, reason} ->
              send_error(conn, reason)
          end
        end
      end

    handler_module(e, action, body, opts)
  end

  defp custom_action_args(e, action_opts, opts) do
    schema = Keyword.fetch!(opts, :schema)

    args = normalize_custom_action_args(e, action_opts)
    arg_names = arg_names(args)

    vars =
      Enum.flat_map(args, fn
        {name, kind, []} ->
          [
            quote do
              {:ok, unquote(Ast.var(name))} <-
                cast_param(conn, unquote(to_string(name)), unquote(kind))
            end
          ]

        {name, kind, rel: rel} ->
          target = Entity.find_entity!(schema, rel[:target])

          [
            quote do
              {:ok, unquote(Ast.var(name))} <-
                cast_param(conn, unquote(to_string(name)), unquote(kind))
            end,
            quote do
              {:ok, unquote(Ast.var(name))} <-
                unquote(target[:api_module]).get_by_id(unquote(Ast.var(name)))
            end
          ]
      end)

    args =
      Enum.map(arg_names, fn name ->
        quote do
          args <- Map.put(args, unquote(name), unquote(Ast.var(name)))
        end
      end)

    {vars, args}
  end

  defp handler_module(e, action, body, opts) do
    handler = handler(action, e)
    auth_action = opts[:auth_action] || action
    auth_entity = opts[:auth_entity] || e[:name]
    body = if is_list(body), do: body, else: [body]

    quote do
      defmodule unquote(handler) do
        use Plug.Builder
        import RouterHelper

        plug(:auth_context)
        plug(:handle)

        def auth_context(conn, _opts) do
          assign(conn, :graphism, %{action: unquote(auth_action), entity: unquote(auth_entity)})
        end

        unquote_splicing(body)
      end
    end
  end

  defp routes(schema), do: Enum.flat_map(schema, fn e -> entity_routes(e, schema) end)

  defp entity_routes(e, schema) do
    [
      aggregation_routes(e) ++
        standard_routes(e) ++
        list_children_routes(e, schema) ++
        list_by_non_unique_key_routes(e) ++
        list_by_custom_query_routes(e) ++
        read_by_unique_key_routes(e) ++
        custom_action_routes(e)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp standard_routes(e) do
    Enum.map(e[:actions], fn {action, _opts} ->
      method = method(action)
      path = path(action, e)
      handler = handler(action, e)

      quote do
        unquote(method)(unquote(path), to: unquote(handler))
      end
    end)
  end

  defp aggregation_routes(e) do
    [maybe_aggregate_all_route(e)]
  end

  defp list_children_routes(e, schema) do
    e
    |> Entity.relations()
    |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
    |> Enum.flat_map(fn rel ->
      target = Entity.find_entity!(schema, rel[:target])

      if Entity.action?(target, :list) do
        path = Route.for_children(e, rel)
        aggregation_path = Route.for_children_aggregation(e, rel)
        handler = rel |> list_children_action() |> handler(e)
        aggregation_handler = rel |> aggregate_children_action() |> handler(e)

        [
          quote do
            get(unquote(path), to: unquote(handler))
          end,
          quote do
            get(unquote(aggregation_path), to: unquote(aggregation_handler))
          end
        ]
      else
        []
      end
    end)
  end

  defp list_by_non_unique_key_routes(e) do
    if Entity.action?(e, :list) do
      e
      |> Entity.non_unique_keys()
      |> Enum.flat_map(fn key ->
        path = Route.for_key(e, key)
        handler = key |> list_by_non_unique_key_action() |> handler(e)
        aggregation_path = Route.for_key_aggregation(e, key)
        aggregation_handler = key |> aggregate_by_non_unique_key_action() |> handler(e)

        [
          quote do
            get(unquote(path), to: unquote(handler))
          end,
          quote do
            get(unquote(aggregation_path), to: unquote(aggregation_handler))
          end
        ]
      end)
    else
      []
    end
  end

  defp list_by_custom_query_routes(e) do
    e
    |> Entity.custom_queries()
    |> Enum.flat_map(fn {action, opts} ->
      args = Enum.map(opts[:args] || [], fn {name, _} -> name end)
      path = Route.for_action(e, action, args)
      handler = handler(action, e)
      aggregation_path = Route.for_action_aggregation(e, action, args)
      aggregation_handler = action |> aggregate_by_custom_query_action() |> handler(e)

      [
        quote do
          get(unquote(path), to: unquote(handler))
        end,
        quote do
          get(unquote(aggregation_path), to: unquote(aggregation_handler))
        end
      ]
    end)
  end

  defp read_by_unique_key_routes(e) do
    if Entity.action?(e, :read) do
      e
      |> Entity.unique_keys_and_attributes()
      |> Enum.map(fn key ->
        path = Route.for_key(e, key)
        handler = key |> read_by_unique_key_action() |> handler(e)

        quote do
          get(unquote(path), to: unquote(handler))
        end
      end)
    else
      []
    end
  end

  defp maybe_aggregate_all_route(e) do
    if Entity.action?(e, :list) do
      path = Route.for_aggregation(e)
      handler = handler(:aggregate, e)

      quote do
        get(unquote(path), to: unquote(handler))
      end
    else
      nil
    end
  end

  defp custom_action_routes(e) do
    e
    |> Entity.custom_mutations()
    |> Enum.map(fn {name, _opts} ->
      path = Route.for_action(e, name)
      handler = handler(name, e)

      quote do
        post(unquote(path), to: unquote(handler))
      end
    end)
  end

  defp normalize_custom_action_args(e, opts) do
    Enum.map(opts[:args] || [], fn
      {name, kind} ->
        {name, kind, []}

      name ->
        case Entity.attribute_or_relation(e, name) do
          {:attribute, attr} -> {name, attr[:kind], []}
          {:relation, rel} -> {name, :id, rel: rel}
        end
    end)
  end

  defp arg_names(args) do
    Enum.map(args, fn {name, _, _} -> name end)
  end

  defp method(:read), do: :get
  defp method(:list), do: :get
  defp method(:create), do: :post
  defp method(:update), do: :put
  defp method(:delete), do: :delete

  defp path(:read, e), do: Route.for_item(e)
  defp path(:list, e), do: Route.for_collection(e)
  defp path(:create, e), do: Route.for_collection(e)
  defp path(:update, e), do: Route.for_item(e)
  defp path(:delete, e), do: Route.for_item(e)

  defp handler(action, e) do
    Module.concat([e[:handler_module], Inflex.camelize(action)])
  end

  def join_fields(key), do: Enum.join(key[:fields], "_and_")

  defp read_by_unique_key_action(key) do
    fields = join_fields(key)

    String.to_atom("read_by_#{fields}")
  end

  defp list_children_action(rel) do
    String.to_atom("list_#{rel[:name]}")
  end

  defp aggregate_children_action(rel) do
    String.to_atom("aggregate_#{rel[:name]}")
  end

  defp list_by_non_unique_key_action(key) do
    fields = join_fields(key)

    String.to_atom("list_by_#{fields}")
  end

  defp aggregate_by_non_unique_key_action(key) do
    fields = join_fields(key)

    String.to_atom("aggregate_by_#{fields}")
  end

  defp aggregate_by_custom_query_action(name) do
    String.to_atom("aggregate_#{name}")
  end
end
