defmodule Graphism.Evaluate do
  @moduledoc false

  def evaluate(nil, _), do: nil
  def evaluate(value, []), do: value

  def evaluate(_, %{app: app, env: env, key: key}) do
    app |> Application.fetch_env!(env) |> Keyword.fetch!(key)
  end

  def evaluate(_, {:literal, v}), do: v

  def evaluate(%{__struct__: _} = context, [:**]), do: context

  def evaluate(%{__struct__: schema} = context, [field]) when is_atom(field) do
    case schema.field_spec(field) do
      {:error, :unknown_field} ->
        if schema.entity() == field do
          context
        else
          Map.get(context, field)
        end

      {:ok, _kind, _column} ->
        Map.fetch!(context, field)

      {:ok, :has_many, _, _next_schema} ->
        context
        |> relation(field)
        |> Enum.reject(&is_nil/1)

      {:ok, :belongs_to, _, _, _column} ->
        relation(context, field)
    end
  end

  def evaluate(%{__struct__: model} = context, [:**, ancestor | rest]) do
    case model.shortest_path(ancestor) do
      [] ->
        if model.name() == ancestor do
          evaluate(context, rest)
        else
          nil
        end

      path ->
        evaluate(context, path ++ rest)
    end
  end

  def evaluate(context, [field | _] = paths) when is_map(context) and is_list(field) do
    paths
    |> Enum.map(&evaluate(context, &1))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def evaluate(%{__struct__: schema} = context, [field | rest]) do
    case schema.field_spec(field) do
      {:error, :unknown_field} ->
        nil

      {:ok, _kind, _column} ->
        nil

      {:ok, :has_many, _, _next_schema} ->
        context
        |> relation(field)
        |> Enum.map(&evaluate(&1, rest))
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, :belongs_to, _, _next_schema, _} ->
        context
        |> relation(field)
        |> evaluate(rest)
    end
  end

  def evaluate(context, [field | rest]) when is_map(context) and is_atom(field) do
    context
    |> Map.get(field)
    |> evaluate(rest)
  end

  defp relation(%{__struct__: schema, id: id} = context, field) do
    with rel when rel != nil <- Map.get(context, field) do
      if unloaded?(rel) do
        key = {id, field}

        with nil <- Process.get(key) do
          rel = context |> schema.repo().preload(field) |> Map.get(field)
          Process.put(key, rel)
          rel
        end
      else
        rel
      end
    end
  end

  defp unloaded?(%{__struct__: Ecto.Association.NotLoaded}), do: true
  defp unloaded?(_), do: false
end
