defmodule Graphism.QueryBuilder do
  @moduledoc false

  defstruct joins: [], filters: []

  import Ecto.Query

  @doc """
  Applies an empty set

  Depending on how the builder is combined with other builders, this might yield no results
  """
  def empty_set(%__MODULE__{} = builder) do
    %{builder | filters: builder.filters ++ [:empty_set]}
  end

  @doc """
  Applies the given builder to the given query

  First, it applies joins, then fitlers, finally sorting
  """
  def build(query, %__MODULE__{} = builder) do
    query
    |> distinct(true)
    |> join(builder.joins)
    |> filter(builder.filters)
  end

  @doc """
  Filters the given query, with the given list of filters

  """
  def filter(query, nil), do: query
  def filter(query, filter) when is_list(filter), do: filter(query, {:and, filter})

  def filter(query, filter) do
    filter = filter(filter)

    where(query, ^filter)
  end

  defp filter({:and, filter}) do
    Enum.reduce(filter, nil, fn
      filter, nil ->
        filter(filter)

      filter, prev ->
        compiled = filter(filter)

        dynamic(^prev and ^compiled)
    end)
  end

  defp filter({:or, filter}) do
    Enum.reduce(filter, nil, fn
      filter, nil ->
        filter(filter)

      filter, prev ->
        compiled = filter(filter)

        dynamic(^prev or ^compiled)
    end)
  end

  defp filter(:empty_set) do
    dynamic(false)
  end

  defp filter({:not, filter}) do
    filter = filter(filter)

    dynamic(not (^filter))
  end

  defp filter({{binding, column}, :eq, nil}) do
    dynamic([{^binding, x}], is_nil(field(x, ^column)))
  end

  defp filter({{binding, column}, :neq, nil}) do
    dynamic([{^binding, x}], not is_nil(field(x, ^column)))
  end

  defp filter({{binding, column}, :eq, value}) do
    dynamic([{^binding, x}], field(x, ^column) == ^value)
  end

  defp filter({{binding, column}, :like, value}) do
    value = "%#{value}%"

    dynamic([{^binding, x}], ilike(field(x, ^column), ^value))
  end

  defp filter({{binding, column}, :neq, value}) do
    dynamic([{^binding, x}], field(x, ^column) != ^value)
  end

  defp filter({{binding, column}, :gt, value}) do
    dynamic([{^binding, x}], field(x, ^column) > ^value)
  end

  defp filter({{binding, column}, :gte, value}) do
    dynamic([{^binding, x}], field(x, ^column) >= ^value)
  end

  defp filter({{binding, column}, :lt, value}) do
    dynamic([{^binding, x}], field(x, ^column) < ^value)
  end

  defp filter({{binding, column}, :lte, value}) do
    dynamic([{^binding, x}], field(x, ^column) <= ^value)
  end

  defp filter({{binding, column}, :in, values}) when is_list(values) do
    dynamic([{^binding, x}], field(x, ^column) in ^values)
  end

  defp filter({{binding, column}, :in, value}) do
    dynamic([{^binding, x}], field(x, ^column) == ^value)
  end

  @doc """
  Joins the given query, with the given list of joins

  """
  def join(query, nil), do: query

  def join(query, joins) when is_list(joins) do
    joins
    |> Enum.uniq()
    |> Enum.reduce(query, fn
      {join_type, {remote_model, remote_alias, remote_column}, {local_alias, local_column}}, query ->
        join_type =
          case join_type do
            :join -> :inner
            :left_join -> :left
          end

        join(query, join_type, [{^local_alias, x}], r in ^remote_model,
          as: ^remote_alias,
          on: field(x, ^local_column) == field(r, ^remote_column)
        )
    end)
  end

  @doc """
  Combines multiple query builders into a single one
  """
  def combine(builders, op) do
    %__MODULE__{
      joins: builders |> Enum.flat_map(& &1.joins) |> Enum.uniq(),
      filters: [{op, Enum.flat_map(builders, & &1.filters)}]
    }
  end
end
