defmodule Graphism.Policy do
  @moduledoc false

  alias Graphism.Scope
  alias Graphism.Scope.Expression

  def scope?(scopes, name) do
    Map.has_key?(scopes, name)
  end

  def scope_from(name, do: {:any, _, exprs}) do
    %{any: Enum.map(exprs, &expression/1), name: name}
  end

  def scope_from(name, do: {:all, _, exprs}) do
    %{all: Enum.map(exprs, &expression/1), name: name}
  end

  def scope_from(name, do: {:__block__, _, [{:not, _, [expr]}]}) do
    expr
    |> expression()
    |> negate()
    |> Map.put(:name, name)
  end

  def scope_from(name, do: {:__block__, _, []}) do
    raise "expression for scope #{inspect(name)} is empty"
  end

  def scope_from(name, do: expr) do
    expr
    |> expression()
    |> Map.put(:name, name)
  end

  def scope_from(name, _block) do
    raise "scope #{inspect(name)} is declared, but not properly defined. Please provide a valid expression."
  end

  defp op(:==), do: :eq
  defp op(:!=), do: :neq
  defp op(op) when is_atom(op), do: op
  defp op(other), do: raise("scope operator #{inspect(other)} is not supported")

  defp negate(expr) when is_map(expr) do
    Map.put(expr, :op, negate(expr[:op]))
  end

  defp negate(:in), do: :not_in
  defp negate(:eq), do: :neq

  defp expression({:any, _, exprs}) do
    %{any: Enum.map(exprs, &expression/1)}
  end

  defp expression({:all, _, exprs}) do
    %{all: Enum.map(exprs, &expression/1)}
  end

  defp expression({op, _, [prop, value]}) do
    %{op: op(op), prop: prop(prop), value: value(value)}
  end

  defp expression(name) when is_atom(name), do: name

  defp value({:env, _, [app, {:__aliases__, _, env}, key]}) do
    %{app: app, env: Module.concat(env), key: key}
  end

  defp value(nil), do: {:literal, nil}
  defp value(v) when is_boolean(v), do: {:literal, v}
  defp value({:literal, _, [v]}), do: {:literal, v}

  defp value(v) when is_binary(v) do
    split(v)
  end

  defp value([v | _] = values) when is_binary(v) do
    Enum.map(values, &value/1)
  end

  defp value(other), do: other

  defp prop(v) do
    split(v)
  end

  defp split(v) when is_binary(v) do
    v
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp split(v) when is_list(v) do
    Enum.map(v, &split/1)
  end

  defp split(v) when is_atom(v), do: v

  def resolve_scopes(scopes) do
    scopes
    |> Enum.map(fn {name, spec} -> {name, resolve_scope(spec, scopes)} end)
    |> Enum.into(%{})
  end

  defp resolve_scope(name, scopes) when is_atom(name) do
    scope = Map.get(scopes, name)

    unless scope do
      raise "No such scope #{inspect(name)} in #{inspect(Map.keys(scopes))}"
    end

    scope
  end

  defp resolve_scope(%{any: children}, scopes) do
    %{any: Enum.map(children, &resolve_scope(&1, scopes))}
  end

  defp resolve_scope(%{all: children}, scopes) do
    %{all: Enum.map(children, &resolve_scope(&1, scopes))}
  end

  defp resolve_scope(%{op: _, prop: _, value: _} = scope, _scopes) do
    scope
  end

  @doc """
  Transforms a policy into a scope

  It is practicall the same information, in a slighly different shape
  """
  def to_scope([]), do: nil

  def to_scope({:allow, policy}) do
    to_scope(policy)
  end

  def to_scope(%{all: expressions}) do
    to_scope(:all, expressions)
  end

  def to_scope(%{any: expressions}) do
    to_scope(:one, expressions)
  end

  def to_scope(%{op: op, prop: prop, value: value} = policy) do
    %Scope{
      name: Map.get(policy, :name),
      expression: %Expression{
        op: op,
        args: [prop, value]
      }
    }
  end

  defp to_scope(combinator, expressions) do
    %Scope{
      expression: %Expression{
        op: combinator,
        args: Enum.map(expressions, &to_scope/1)
      }
    }
  end
end
