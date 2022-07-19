defmodule Graphism.Api do
  @moduledoc "Generaes entity api modules"

  alias Graphism.{Ast, Entity}

  def api_module(e, schema, hooks, opts) do
    schema_module = e[:schema_module]
    repo_module = opts[:repo]

    case Entity.virtual?(e) do
      false ->
        api_funs =
          []
          |> with_api_convenience_functions(e, schema_module, repo_module)
          |> with_query_preload_fun(e, schema)
          |> with_optional_query_pagination_fun(e, schema_module)
          |> with_query_scope_fun(e)
          |> with_api_list_funs(e, schema_module, repo_module, schema, hooks)
          |> with_api_aggregate_funs(e, schema_module, repo_module, schema, hooks)
          |> with_api_read_funs(e, schema_module, repo_module, schema)
          |> with_api_create_fun(e, schema_module, repo_module, schema)
          |> with_api_batch_create_fun(e, schema_module, repo_module, schema)
          |> with_api_update_fun(e, schema_module, repo_module, schema)
          |> with_api_delete_fun(e, schema_module, repo_module, schema)
          |> with_api_custom_funs(e, schema_module, repo_module, schema, hooks)
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
          |> with_api_custom_funs(e, schema_module, repo_module, schema, hooks)
          |> List.flatten()

        quote do
          defmodule unquote(e[:api_module]) do
            (unquote_splicing(api_funs))
          end
        end
    end
  end

  defp with_api_convenience_functions(funs, e, _schema, repo_module) do
    [
      quote do
        def relation(parent, child) do
          case Map.get(parent, child) do
            %{id: _} = rel ->
              rel

            nil ->
              nil

            _ ->
              meta = %{entity: unquote(e[:name]), relation: child}

              :telemetry.span([:graphism, :relation], meta, fn ->
                {parent
                 |> unquote(repo_module).preload(child)
                 |> Map.get(child), meta}
              end)
          end
        end
      end
      | funs
    ]
  end

  defp with_query_preload_fun(funs, e, _schema) do
    preloads = Entity.preloads(e)

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

  defp with_query_scope_fun(funs, e) do
    [
      quote do
        defp scoped_query(query, mod, context, name) do
          meta = %{entity: unquote(e[:name]), kind: :scope, value: name}

          :telemetry.span([:graphism, :scope], meta, fn ->
            {mod.scope(query, context), meta}
          end)
        end
      end
      | funs
    ]
  end

  defp with_api_list_funs(funs, e, schema_module, repo_module, _schema, hooks) do
    action_opts = Entity.action_for(e, :list)
    scope_mod = Entity.scope_hook!(e, action_opts, :list, hooks)

    [
      quote do
        def list(context \\ %{}) do
          meta = %{entity: unquote(e[:name]), action: :list}

          :telemetry.span([:graphism, :api], meta, fn ->
            {do_list(context), meta}
          end)
        end

        defp do_list(context) do
          query = from(unquote(Ast.var(e)) in unquote(schema_module))

          with query <- scoped_query(query, unquote(scope_mod), context, :list),
               {:ok, query} <- maybe_paginate(query, context),
               {:ok, query} <- maybe_with_preloads(query) do
            {:ok, unquote(repo_module).all(query)}
          end
        end
      end
      | e[:relations]
        |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
        |> Enum.map(fn rel ->
          fun_name = String.to_atom("list_by_#{rel[:name]}")

          quote do
            def unquote(fun_name)(id, context \\ %{}) do
              query =
                from(unquote(Ast.var(rel)) in unquote(schema_module))
                |> where([q], q.unquote(String.to_atom("#{rel[:name]}_id")) == ^id)

              with query <- scoped_query(query, unquote(scope_mod), context, unquote(fun_name)),
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

    action_opts = Entity.action_for(e, :list)
    scope_mod = Entity.scope_hook!(e, action_opts, :list, hooks)

    [
      quote do
        def aggregate(context \\ %{}) do
          query =
            from(
              unquote(Ast.var(e)) in unquote(schema_module),
              unquote(query_opts)
            )

          with query <- scoped_query(query, unquote(scope_mod), context, :aggregate) do
            {:ok, %{count: unquote(repo_module).aggregate(query, :count)}}
          end
        end
      end
      | e[:relations]
        |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
        |> Enum.map(fn rel ->
          fun_name = String.to_atom("aggregate_by_#{rel[:name]}")

          quote do
            def unquote(fun_name)(id, context \\ %{}) do
              query =
                from(
                  unquote(Ast.var(rel)) in unquote(schema_module),
                  unquote(query_opts)
                )
                |> where([q], q.unquote(String.to_atom("#{rel[:name]}_id")) == ^id)

              with query <- scoped_query(query, unquote(scope_mod), context, unquote(fun_name)) do
                {:ok, %{count: unquote(repo_module).aggregate(query, :count)}}
              end
            end
          end
        end)
    ] ++ funs
  end

  defp with_api_read_funs(funs, e, schema_module, repo_module, schema) do
    [
      get_by_id_api_fun(e, schema_module, repo_module, schema),
      get_by_id_bang_api_fun(schema_module)
    ] ++
      get_by_key_api_funs(e, schema_module, repo_module, schema) ++
      get_by_unique_attrs_api_funs(e, schema_module, repo_module, schema) ++ funs
  end

  defp with_api_create_fun(funs, e, schema_module, repo_module, _schema) do
    parent_relations = Entity.attrs_with_parent_relations(e)

    insert =
      quote do
        {:ok, unquote(Ast.var(e))} <-
          %unquote(schema_module){}
          |> unquote(schema_module).changeset(unquote(Ast.var(:attrs)))
          |> unquote(repo_module).insert(opts)
      end

    refetch =
      if Entity.refetch?(e) do
        quote do
          {:ok, unquote(Ast.var(e))} <- get_by_id(unquote(Ast.var(e)).id, opts)
        end
      else
        nil
      end

    before_hooks = Entity.hooks(e, :before, :create)
    after_hooks = Entity.hooks(e, :after, :create)

    fun =
      quote do
        def create(
              unquote_splicing(
                e
                |> Entity.parent_relations()
                |> Ast.vars()
              ),
              unquote(Ast.var(:attrs)),
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
                   |> List.flatten()
                   |> Enum.reject(&is_nil/1)
                 ) do
              unquote(Ast.var(e))
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
    parent_relations = Entity.attrs_with_parent_relations(e)

    update =
      quote do
        {:ok, unquote(Ast.var(e))} <-
          unquote(Ast.var(e))
          |> unquote(schema_module).changeset(unquote(Ast.var(:attrs)))
          |> unquote(repo_module).update()
      end

    refetch =
      if Entity.refetch?(e) do
        quote do
          {:ok, unquote(Ast.var(e))} <- get_by_id(unquote(Ast.var(e)).id, opts)
        end
      else
        nil
      end

    before_hooks = Entity.hooks(e, :before, :update)
    after_hooks = Entity.hooks(e, :after, :update)

    fun =
      quote do
        def update(
              unquote_splicing(
                e
                |> Entity.parent_relations()
                |> Ast.vars()
              ),
              unquote(Ast.var(e)),
              unquote(Ast.var(:attrs)),
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
                   |> List.flatten()
                   |> Enum.reject(&is_nil/1)
                 ) do
              unquote(Ast.var(e))
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
    before_hooks = Entity.hooks(e, :before, :delete)
    after_hooks = Entity.hooks(e, :after, :delete)

    delete =
      quote do
        {:ok, unquote(Ast.var(:attrs))} <-
          unquote(Ast.var(:attrs))
          |> unquote(schema_module).delete_changeset()
          |> unquote(repo_module).delete()
      end

    fun =
      quote do
        def delete(%unquote(schema_module){} = unquote(Ast.var(:attrs))) do
          unquote(repo_module).transaction(fn ->
            with unquote_splicing(
                   [
                     before_hooks,
                     delete,
                     after_hooks
                   ]
                   |> List.flatten()
                   |> Enum.reject(&is_nil/1)
                 ) do
              unquote(Ast.var(:attrs))
            else
              {:error, e} ->
                unquote(repo_module).rollback(e)
            end
          end)
        end
      end

    [fun | funs]
  end

  defp with_api_custom_funs(funs, e, schema_module, repo_module, schema, hooks) do
    custom_action_funs =
      e
      |> Entity.custom_mutations()
      |> Enum.map(fn {action, opts} ->
        api_custom_action_fun(e, action, opts, schema_module, repo_module, schema, hooks)
      end)

    custom_list_funs =
      e
      |> Entity.custom_queries()
      |> Enum.flat_map(fn {action, opts} ->
        [
          api_custom_list_fun(e, action, opts, schema_module, repo_module, schema, hooks),
          api_custom_list_aggregate_fun(e, action, opts, schema_module, repo_module, schema, hooks)
        ]
      end)

    funs ++ custom_action_funs ++ custom_list_funs
  end

  defp api_custom_action_fun(e, action, opts, _schema_module, _repo_module, _schema, _hooks) do
    using_mod = opts[:using]

    unless using_mod do
      raise "custom action #{action} of #{e[:name]} does not define a :using option"
    end

    quote do
      def unquote(action)(args, context \\ %{}) do
        unquote(using_mod).execute(args, context)
      end
    end
  end

  defp api_custom_list_fun(e, action, opts, _schema_module, repo_module, _schema, hooks) do
    using_mod = opts[:using]
    scope_mod = Entity.scope_hook!(e, opts, action, hooks)

    unless using_mod do
      raise "custom action #{action} of #{e[:name]} does not define a :using option"
    end

    quote do
      def unquote(action)(args, context \\ %{}) do
        with {:ok, query} <- unquote(using_mod).execute(args, context),
             query <- scoped_query(query, unquote(scope_mod), context, unquote(action)),
             {:ok, query} <- maybe_paginate(query, context) do
          {:ok, unquote(repo_module).all(query)}
        end
      end
    end
  end

  defp api_custom_list_aggregate_fun(e, action, opts, _schema_module, repo_module, _schema, hooks) do
    fun_name = String.to_atom("aggregate_#{action}")
    using_mod = opts[:using]
    scope_mod = Entity.scope_hook!(e, opts, action, hooks)

    unless using_mod do
      raise "custom action #{action} of #{e[:name]} does not define a :using option"
    end

    quote do
      def unquote(fun_name)(args, context \\ %{}) do
        with {:ok, query} <- unquote(using_mod).execute(args, context),
             query <- scoped_query(query, unquote(scope_mod), context, unquote(action)) do
          {:ok, %{count: unquote(repo_module).aggregate(query, :count)}}
        end
      end
    end
  end

  defp entity_aggregate_query_opts(_e, _schema) do
    []
  end

  defp get_by_id_api_fun(e, schema_module, repo_module, _schema) do
    preloads = Entity.preloads(e)

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
    preloads = Entity.preloads(e)

    e
    |> Entity.unique_keys()
    |> Enum.map(fn key ->
      fun_name = Entity.get_by_key_fun_name(key)

      args =
        Enum.map(key[:fields], fn name ->
          quote do
            unquote(Ast.var(name))
          end
        end)

      filters =
        Enum.map(key[:fields], fn field ->
          case Entity.relation?(e, field) do
            nil ->
              quote do
                {unquote(field), unquote(Ast.var(field))}
              end

            _ ->
              quote do
                {unquote(String.to_atom("#{field}_id")), unquote(Ast.var(field))}
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
    preloads = Entity.preloads(e)

    e[:attributes]
    |> Enum.filter(&Entity.unique?(&1))
    |> Enum.map(fn attr ->
      scope_args =
        (e[:opts][:scope] || [])
        |> Enum.map(fn rel ->
          Ast.var(rel)
        end)

      args =
        scope_args ++
          [
            Ast.var(attr)
          ]

      quote do
        def unquote(String.to_atom("get_by_#{attr[:name]}"))(unquote_splicing(args), opts \\ []) do
          value =
            case is_atom(unquote(Ast.var(attr))) do
              true ->
                "#{unquote(Ast.var(attr))}"

              false ->
                unquote(Ast.var(attr))
            end

          filters = [
            unquote_splicing(
              ((e[:opts][:scope] || [])
               |> Enum.map(fn arg ->
                 column_name = String.to_atom("#{arg}_id")

                 quote do
                   {unquote(column_name), unquote(Ast.var(arg))}
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
end
