defmodule Graphism.Scope do
  @moduledoc false

  alias Graphism.Evaluate
  alias Graphism.QueryBuilder

  defstruct [:name, :expression]

  defmodule Expression do
    defstruct [:op, :args]
  end

  @doc """
  Scopes a query that relates to a model.

  If no scope is given, the query itself is returned
  """
  def scope(_model, query, nil, _params), do: query

  def scope(model, query, %__MODULE__{} = scope, params) do
    qb = build(model, scope, params)
    query = QueryBuilder.build(query, qb)

    # IO.inspect(model: model, query_builder: qb, query: query)

    query
  end

  @doc """
  Debugs the given scope
  """
  def debug(args) when is_list(args), do: Enum.map(args, &debug/1)
  def debug(%{expression: %{op: op, args: args}}) when op in [:one, :all], do: {op, debug(args)}
  def debug(_arg), do: "a"

  @doc """
  Transforms the given scope, into a query builder struct
  """
  def build(model, scope, params \\ %{}) do
    case scope.expression.op do
      :one -> combine(model, scope.expression.args, params, :or)
      :all -> combine(model, scope.expression.args, params, :and)
      op -> filter(model, op, scope.expression.args, params)
    end
  end

  defp combine(model, args, params, op) do
    args
    |> Enum.map(&build(model, &1, params))
    |> QueryBuilder.combine(op)
  end

  defp filter(model, op, [left, right], params) do
    builder = %QueryBuilder{}
    value = Evaluate.evaluate(params, right)

    binding = [model.name]

    do_filter(model, binding, left, op, value, builder)
  end

  defp do_filter(model, binding, [], op, value, builder) do
    alias = binding_alias(binding)

    case safe_value(value) do
      {:error, value} ->
        raise_invalid_filter(model, :id, op, value)

      :empty_set ->
        QueryBuilder.empty_set(builder)

      value ->
        filter = {{alias, :id}, op, value}
        %{builder | filters: builder.filters ++ [filter]}
    end
  end

  defp do_filter(model, binding, [:**], op, value, builder) do
    do_filter(model, binding, [], op, value, builder)
  end

  defp do_filter(model, binding, [:@ | rest], op, value, builder) do
    do_filter(model, binding, rest, op, value, builder)
  end

  defp do_filter(model, binding, [:**, field | rest], op, value, builder) do
    case model.shortest_path(field) do
      [] ->
        if model.name() == field do
          do_filter(model, binding, rest, op, value, builder)
        else
          QueryBuilder.empty_set(builder)
        end

      path ->
        do_filter(model, binding, path ++ rest, op, value, builder)
    end
  end

  defp do_filter(model, binding, [field], op, value, builder) do
    case model.field(field) do
      {:ok, %{kind: :belongs_to} = rel} ->
        alias = binding_alias(binding)

        case safe_value(value) do
          {:error, value} ->
            raise_invalid_filter(model, field, op, value)

          :empty_set ->
            QueryBuilder.empty_set(builder)

          value ->
            filter = {{alias, rel.column_name}, op, value}
            %{builder | filters: builder.filters ++ [filter]}
        end

      {:ok, %{kind: :has_many} = rel} ->
        parent_binding = binding
        parent_alias = binding_alias(parent_binding)
        child_binding = binding ++ [rel.name]
        child_alias = binding_alias(child_binding)

        join = {:left_join, {rel.target.module, child_alias, rel.inverse.column_name}, {parent_alias, :id}}

        case safe_value(value) do
          {:error, value} ->
            raise_invalid_filter(model, field, op, value)

          :empty_set ->
            QueryBuilder.empty_set(builder)

          value ->
            filter = {{child_alias, :id}, op, value}
            %{builder | joins: builder.joins ++ [join], filters: builder.filters ++ [filter]}
        end

      {:ok, attr} ->
        alias = binding_alias(binding)
        filter = {{alias, attr.column_name}, op, value}

        %{builder | filters: builder.filters ++ [filter]}

      {:error, :unknown_field} ->
        QueryBuilder.empty_set(builder)
    end
  end

  defp do_filter(model, binding, [field | rest], op, value, builder) do
    case model.field(field) do
      {:ok, %{kind: :belongs_to} = rel} ->
        parent_binding = binding ++ [rel.name]
        parent_binding_alias = binding_alias(parent_binding)
        binding_alias = binding_alias(binding)
        parent_model = rel.target.module
        join = {:left_join, {parent_model, parent_binding_alias, :id}, {binding_alias, rel.column_name}}

        builder = %{builder | joins: builder.joins ++ [join]}

        do_filter(parent_model, parent_binding, rest, op, value, builder)

      {:ok, %{kind: :has_many} = rel} ->
        parent_binding = binding
        parent_alias = binding_alias(parent_binding)
        child_binding = binding ++ [rel.name]
        child_alias = binding_alias(child_binding)
        child_model = rel.target.module

        join = {:left_join, {child_model, child_alias, rel.inverse.column_name}, {parent_alias, :id}}

        builder = %{builder | joins: builder.joins ++ [join]}

        do_filter(child_model, child_binding, rest, op, value, builder)

      {:ok, _attr} ->
        QueryBuilder.empty_set(builder)

      {:error, :unknown_field} ->
        if model.name() == field do
          do_filter(model, binding, rest, op, value, builder)
        else
          QueryBuilder.empty_set(builder)
        end
    end
  end

  defp binding_alias(binding) do
    binding
    |> Enum.map_join("_", &to_string/1)
    |> String.to_atom()
  end

  defp safe_value(nil), do: nil
  defp safe_value([]), do: :empty_set
  defp safe_value(%{id: id}), do: id

  defp safe_value(items) when is_list(items) do
    if Enum.all?(items, &match?(%{id: _}, &1)) do
      Enum.map(items, & &1.id)
    else
      {:error, items}
    end
  end

  defp safe_value(id) when is_binary(id), do: id
  defp safe_value(other), do: {:error, other}

  defp raise_invalid_filter(model, field, op, value) do
    raise ArgumentError, """
    Attempting to filter on field #{inspect(field)} of entity #{inspect(model)}
    using value:

      #{inspect(value)}

    which is not supported when using the #{inspect(op)} operator.
    """
  end
end
