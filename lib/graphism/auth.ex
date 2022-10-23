defmodule Graphism.Auth do
  @moduledoc "Authorization module definition"

  def auth_funs(schema, policies, roles) do
    [
      role_fun(roles),
      combine_policies_fun(),
      reduce_policies_fun(),
      allow_fun(schema, policies),
      scope_fun(schema, policies),
      allow_helper_fun()
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

  defp allow_fun(schema, policies) do
    for e <- schema, {action, opts} <- e[:actions] do
      case opts[:policies] do
        nil ->
          default_allow_fun(e[:name], action)

        action_policies ->
          action_policies = resolve_policies(action_policies, policies, e[:name], action)

          quote do
            def allow?(args, %{graphism: %{entity: unquote(e[:name]), action: unquote(action)}} = context) do
              context
              |> with_role()
              |> allow?(unquote(Macro.escape(action_policies)), args, context)
            end
          end
      end
    end ++ [default_allow_fun()]
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
        raise "No such policy #{inspect(name)} in #{inspect(Map.keys(policies))} for action #{inspect(action)} of entity
          #{inspect(entity)}"

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
      def allow?(_args, %{graphism: %{entity: unquote(entity), action: unquote(action)}}), do: true
    end
  end

  defp default_allow_fun do
    quote do
      def allow?(_args, _context), do: true
    end
  end

  defp scope_fun(_schema, _policies) do
    quote do
      def scope(q, _context), do: q
    end
  end

  defp allow_helper_fun do
    quote do
      defp allow?(nil, _, _, _), do: false
      defp allow?([], _, _, _), do: false

      defp allow?(roles, policies, args, context) do
        roles
        |> reduce_policies(policies)
        |> allow?(args, context)
      end

      defp allow?(%{any: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case allow?(policy, args, context) do
            true -> {:halt, true}
            false -> {:cont, false}
          end
        end)
      end

      defp allow?(%{all: policies}, args, context) do
        Enum.reduce_while(policies, false, fn policy, _ ->
          case allow?(policy, args, context) do
            true -> {:cont, true}
            false -> {:halt, false}
          end
        end)
      end

      defp allow?(%{action: action, prop: prop, value: value, op: op}, args, context) do
        context = Map.put(context, :args, args)
        prop = evaluate(context, prop)
        value = evaluate(context, value)
        result = compare(prop, value, op)
        action = if result, do: action, else: :deny

        allow?(%{action: action}, args, context)
      end

      defp allow?(%{action: action}, _, _), do: action == :allow
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
