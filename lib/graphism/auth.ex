defmodule Graphism.Auth do
  @moduledoc "Authorization module definition"

  alias Graphism.Entity

  def auth_funs(schema, scopes, default_policy, roles_expr) do
    unless roles_expr do
      raise "No role expression set in schema and no custom authorization is being used"
    end

    [
      role_fun(roles_expr),
      policy_from_roles_fun(),
      non_list_actions_allow_funs(schema, scopes, default_policy),
      list_actions_allow_funs(schema, scopes, default_policy),
      default_allow_fun(),
      policy_allow_fun(),
      role_allow_fun(),
      import_ecto_query(),
      scope_fun(schema, scopes, default_policy),
      scope_helper_fun()
    ]
    |> Enum.reject(&is_nil/1)
    |> List.flatten()
  end

  defp role_fun(expr) do
    quote do
      def with_role(context) do
        evaluate(context, unquote(expr))
      end
    end
  end

  defp non_list_actions_allow_funs(schema, scopes, default_policy) do
    for e <- schema, {action, opts} <- Entity.non_list_actions(e) do
      policies = Keyword.fetch!(opts, :policies)
      policies = resolve_scopes(policies, scopes)

      quote do
        def allow?(unquote(e[:name]), unquote(action), args, context) do
          context
          |> with_role()
          |> policy_allow?(unquote(Macro.escape(policies)), unquote(default_policy), args, context)
        end
      end
    end
  end

  defp list_actions_allow_funs(schema, scopes, default_policy) do
    for e <- schema, {action, opts} <- Entity.list_actions(e) do
      policies = Keyword.fetch!(opts, :policies)
      policies = resolve_scopes(policies, scopes)

      quote do
        def allow?(unquote(e[:name]), unquote(action), args, context) do
          context
          |> with_role()
          |> role_allow?(unquote(Macro.escape(policies)), unquote(default_policy), args, context)
        end
      end
    end
  end

  defp resolve_scopes(action_policies, scopes) do
    Enum.map(action_policies, fn {action, role, scope} ->
      case resolve_scope(scope, scopes) do
        nil -> {role, action}
        scope -> {role, {action, scope}}
      end
    end)
  end

  defp resolve_scope(name, scopes) when is_atom(name) do
    with scope when scope != nil <- Map.get(scopes, name) do
      resolve_scope(scope, scopes)
    end
  end

  defp resolve_scope([all: list], scopes) when is_list(list) do
    %{all: Enum.map(list, &resolve_scope(&1, scopes))}
  end

  defp resolve_scope([any: list], scopes) when is_list(list) do
    %{any: Enum.map(list, &resolve_scope(&1, scopes))}
  end

  defp resolve_scope(%{name: _, op: _, prop: _, value: _} = scope, _), do: scope

  defp default_allow_fun(entity, action) do
    quote do
      def allow?(_args, %{graphism: %{entity: unquote(entity), action: unquote(action)}}),
        do: true
    end
  end

  defp default_allow_fun do
    quote do
      def allow?(_args, _context), do: true
    end
  end

  defp policy_allow_fun do
    quote do
      defp policy_allow?(roles, _, default_policy, _, _) when is_nil(roles) or roles == [] do
        default_policy == :allow
      end

      defp policy_allow?(roles, policies, default_policy, args, context) do
        case policy_from_roles(roles, policies) do
          [] -> default_policy == :allow
          policy -> do_policy_allow?(policy, args, context)
        end
      end

      defp do_policy_allow?(%{any: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case do_policy_allow?(policy, args, context) do
            true -> {:halt, true}
            false -> {:cont, false}
          end
        end)
      end

      defp do_policy_allow?(%{all: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case do_policy_allow?(policy, args, context) do
            true -> {:cont, true}
            false -> {:halt, false}
          end
        end)
      end

      defp do_policy_allow?({policy, %{prop: prop_spec, value: value_spec, op: op}}, args, context) do
        context = Map.put(context, :args, args)
        prop = evaluate(context, prop_spec)
        value = evaluate(context, value_spec)
        result = compare(prop, value, op)
        with true <- result, do: policy == :allow
      end

      defp do_policy_allow?(:allow, _, _), do: true
      defp do_policy_allow?(:deny, _, _), do: false
    end
  end

  defp role_allow_fun do
    quote do
      defp role_allow?(nil, _, _, _, _), do: false
      defp role_allow?([], _, _, _, _), do: false

      defp role_allow?(roles, policies, _default_policy, _, _) do
        roles
        |> Enum.map(&Keyword.get(policies, &1))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] ->
            false

          _ ->
            # we would need to check if any of these policies are explicitly denying
            # the action. For now, we assume the presence means it is okay
            # and we will let the scope function to filter out results
            true
        end
      end
    end
  end

  defp import_ecto_query do
    quote do
      import Ecto.Query
    end
  end

  defp scope_fun(schema, scopes, _default_policy) do
    for e <- schema, {action, opts} <- e[:actions] do
      policies = Keyword.fetch!(opts, :policies)
      policies = resolve_scopes(policies, scopes)

      quote do
        def scope(unquote(e[:name]), unquote(action), q, context) do
          context
          |> with_role()
          |> do_scope(unquote(Macro.escape(policies)), q, unquote(e[:name]), unquote(e[:schema_module]), context)
        end
      end
    end
  end

  defp scope_helper_fun do
    quote do
      defp do_scope(policy, _, q, _, _, _) when is_nil(policy) or policy == [], do: return_nothing(q)

      defp do_scope(roles, policies, q, entity, schema, context) do
        roles
        |> policy_from_roles(policies)
        |> do_scope(q, entity, schema, context)
      end

      defp do_scope(%{any: policies}, q, entity, schema, context) do
        scope_all(policies, q, entity, schema, context, :insersect)
      end

      defp do_scope(%{all: policies}, q, entity, schema, context) do
        scope_all(policies, q, entity, schema, context, :union)
      end

      defp do_scope({:allow, %{prop: prop, value: value, op: op}}, q, entity, schema, context) do
        value = evaluate(context, value) |> maybe_ids()

        filter(schema, prop, op, value, q, entity)
      end

      defp do_scope(:deny, q, _, _, _), do: return_nothing(q)
      defp do_scope(:allow, q, _, _, _), do: q

      defp scope_all(policies, q, entity, schema, context, op) do
        with nil <-
               Enum.reduce(policies, nil, fn policy, prev ->
                 q = do_scope(policy, q, entity, schema, context)
                 combine_queries(q, prev, op)
               end),
             do: return_nothing(q)
      end

      defp return_nothing(q), do: where(q, [p], 1 == 2)

      defp maybe_ids(%{id: id}), do: id
      defp maybe_ids(items) when is_list(items), do: Enum.map(items, &maybe_ids/1)
      defp maybe_ids(other), do: other

      defp combine_queries(q, q, _), do: q
      defp combine_queries(q, nil, _), do: q
      defp combine_queries(nil, prev, _), do: prev
      defp combine_queries(q, prev, :union), do: Ecto.Query.union(q, ^prev)
      defp combine_queries(q, prev, :intersect), do: Ecto.Query.intersect(q, ^prev)
    end
  end

  defp default_scope_fun(entity, action) do
    quote do
      def scope(q, %{graphism: %{entity: unquote(entity), action: unquote(action)}}),
        do: q
    end
  end

  # defp default_scope_fun do
  #  quote do
  #    def scope(q, _context), do: q
  #  end
  # end

  defp policy_from_roles_fun do
    quote do
      defp policy_from_roles(roles, policies) do
        roles
        |> Enum.map(&Keyword.get(policies, &1))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> []
          [policy] -> policy
          policies -> %{any: policies}
        end
      end
    end
  end
end
