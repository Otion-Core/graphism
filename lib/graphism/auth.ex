defmodule Graphism.Auth do
  @moduledoc "Authorization module definition"

  alias Graphism.Entity

  def auth_funs(schema, policies, roles) do
    [
      role_fun(roles),
      combine_policies_fun(),
      reduce_policies_fun(),
      non_list_actions_allow_funs(schema, policies),
      list_actions_allow_funs(schema, policies),
      default_allow_fun(),
      policy_allow_fun(),
      role_allow_fun(),
      import_ecto_query(),
      scope_fun(schema, policies),
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

  defp non_list_actions_allow_funs(schema, policies) do
    for e <- schema, {action, opts} <- Entity.actions_of_other_kind(e, :list) do
      case opts[:policies] do
        [_ | _] = action_policies ->
          action_policies = resolve_policies(action_policies, policies, e[:name], action)

          quote do
            def allow?(
                  args,
                  %{graphism: %{entity: unquote(e[:name]), action: unquote(action)}} = context
                ) do
              context
              |> with_role()
              |> policy_allow?(unquote(Macro.escape(action_policies)), args, context)
            end
          end

        _ ->
          default_allow_fun(e[:name], action)
      end
    end
  end

  defp list_actions_allow_funs(schema, policies) do
    for e <- schema, {action, opts} <- Entity.actions_of_kind(e, :list) do
      case opts[:policies] do
        [_ | _] = action_policies ->
          action_policies = resolve_policies(action_policies, policies, e[:name], action)

          quote do
            def allow?(
                  args,
                  %{graphism: %{entity: unquote(e[:name]), action: unquote(action)}} = context
                ) do
              context
              |> with_role()
              |> role_allow?(unquote(Macro.escape(action_policies)), args, context)
            end
          end

        _ ->
          default_allow_fun(e[:name], action)
      end
    end
  end

  defp resolve_policies(action_policies, policies, entity, action) do
    Enum.map(action_policies, fn {role, policy} ->
      {role, resolve_policy(policy, policies, entity, action)}
    end)
  end

  defp resolve_policy(%{action: _} = policy, _policies, _, _), do: policy

  defp resolve_policy(name, policies, entity, action) when is_atom(name) do
    case Map.get(policies, name) do
      nil ->
        raise "No such policy #{inspect(name)} in #{inspect(Map.keys(policies))} for action #{inspect(action)} of entity #{inspect(entity)}"

      policy ->
        resolve_policy(policy, policies, entity, action)
    end
  end

  defp resolve_policy([all: list], policies, entity, action) when is_list(list) do
    %{all: Enum.map(list, &resolve_policy(&1, policies, entity, action))}
  end

  defp resolve_policy([any: list], policies, entity, action) when is_list(list) do
    %{any: Enum.map(list, &resolve_policy(&1, policies, entity, action))}
  end

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
      defp policy_allow?(nil, _, _, _), do: false
      defp policy_allow?([], _, _, _), do: false

      defp policy_allow?(roles, policies, args, context) do
        roles
        |> reduce_policies(policies)
        |> policy_allow?(args, context)
      end

      defp policy_allow?(%{any: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case policy_allow?(policy, args, context) do
            true -> {:halt, true}
            false -> {:cont, false}
          end
        end)
      end

      defp policy_allow?(%{all: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case policy_allow?(policy, args, context) do
            true -> {:cont, true}
            false -> {:halt, false}
          end
        end)
      end

      defp policy_allow?(%{action: action, prop: prop_spec, value: value, op: op}, args, context) do
        context = Map.put(context, :args, args)
        prop = evaluate(context, prop_spec)
        value = evaluate(context, value)
        result = compare(prop, value, op)

        IO.inspect(
          context: context,
          prop: prop,
          prop_spec: prop_spec,
          value: value,
          result: result,
          action: action
        )

        with true <- result, do: action == :allow
      end

      defp policy_allow?(%{action: action}, _, _), do: action == :allow
    end
  end

  defp role_allow_fun do
    quote do
      defp role_allow(nil, _, _, _), do: false
      defp role_allow?([], _, _, _), do: false

      defp role_allow(roles, policies, _, _) do
        roles
        |> Enum.map(&Keyword.get(policies, &1))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] ->
            false

          _ ->
            # we need to check if these policies are explicitly denying
            # the action. For now, we assume the presence means it is okay
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

  defp scope_fun(schema, policies) do
    for e <- schema, {action, opts} <- e[:actions] do
      case opts[:policies] do
        [_ | _] = action_policies ->
          action_policies = resolve_policies(action_policies, policies, e[:name], action)

          quote do
            def scope(
                  q,
                  %{graphism: %{entity: unquote(e[:name]), action: unquote(action)}} = context
                ) do
              context
              |> with_role()
              |> scope(unquote(Macro.escape(action_policies)), q, context)
            end
          end

        _ ->
          default_scope_fun(e[:name], action)
      end
    end ++ [default_scope_fun()]
  end

  defp scope_helper_fun do
    quote do
      defp scope(nil, _, q, _), do: return_nothing(q)
      defp scope([], _, q, _), do: return_nothing(q)

      defp scope(roles, policies, q, context) do
        roles
        |> reduce_policies(policies)
        |> scope(q, context)
      end

      defp scope(%{any: policies}, q, context) do
        scope_all(policies, q, context, :insersect)
      end

      defp scope(%{all: policies}, q, context) do
        scope_all(policies, q, context, :unioniiiii)
      end

      defp scope(%{action: action, prop: prop, value: value, op: op}, q, context) do
        schema = context.graphism.schema
        value = evaluate(context, value) |> maybe_ids()
        binding = context.graphism.entity

        filter(schema, prop, op, value, q, binding)
      end

      defp scope(%{action: :deny}, q, _), do: return_nothing(q)
      defp scope(%{action: :allow}, q, _), do: q

      defp scope_all(policies, q, context, op) do
        with nil <-
               Enum.reduce(policies, nil, fn policy, prev ->
                 q = scope(policy, q, context)
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

  defp default_scope_fun do
    quote do
      def scope(q, _context), do: q
    end
  end

  defp reduce_policies_fun do
    quote do
      defp reduce_policies(roles, policies) do
        roles
        |> Enum.map(&Keyword.get(policies, &1))
        |> Enum.reject(&is_nil/1)
        |> case do
          [policy] -> policy
          policies -> combine_policies(policies, :any)
        end
      end
    end
  end

  defp combine_policies_fun do
    quote do
      defp combine_policies([], _) do
        %{action: :deny}
      end

      defp combine_policies(policies, op) do
        %{op => policies}
      end
    end
  end
end
