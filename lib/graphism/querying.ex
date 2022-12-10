defmodule Graphism.Querying do
  @moduledoc """
  Generates convenience functions for powerful generation of complex queries.
  """

  def filter_fun do
    quote do
      import Ecto.Query

      def filter({:intersect, filters}) when is_list(filters) do
        filters
        |> Enum.reduce(nil, fn f, q ->
          f
          |> filter()
          |> combine(q, :intersect)
        end)
      end

      def filter({:union, filters}) when is_list(filters) do
        filters
        |> Enum.reduce(nil, fn f, q ->
          f
          |> filter()
          |> combine(q, :union)
        end)
      end

      def filter({schema, path, op, values}) do
        filter(schema, path, op, values, [])
      end

      def filter({schema, path, op, values, opts}) do
        filter(schema, path, op, values, opts)
      end

      def filter(schema, [first | _] = path, op, value, opts) when is_atom(first) do
        binding = Keyword.get(opts, :as, schema.entity())
        q = schema.query()

        filter(schema, path, op, value, q, binding)
      end

      def filter(schema, [first | _] = paths, op, value, opts) when is_list(first) do
        paths
        |> Enum.reduce(nil, fn path, q ->
          schema
          |> filter(path, op, value, opts)
          |> combine(q, :union)
        end)
      end

      def filter(_, [], _, _, q, _), do: q

      def filter(schema, [:"**", ancestor | rest], op, value, q, last_binding) do
        ancestor_path =
          with [] <- schema.shortest_path_to(ancestor) do
            if rest == [], do: [:id], else: []
          end

        filter(schema, ancestor_path ++ rest, op, value, q, last_binding)
      end

      def filter(schema, [field], op, value, q, last_binding) do
        case schema.field_spec(field) do
          {:error, :unknown_field} ->
            if schema.entity() == field do
              schema.filter(q, :id, op, value, on: last_binding)
            else
              nil
            end

          {:ok, _, _column} ->
            schema.filter(q, field, op, value, on: last_binding)

          {:ok, :has_many, _, _child_schema} ->
            {field, binding} = query_binding(field)
            schema.filter(q, field, op, value, parent: last_binding, child: binding)

          {:ok, :belongs_to, _, _parent_schema, _} ->
            schema.filter(q, field, op, value, parent: last_binding)
        end
      end

      def filter(schema, [field | rest], op, value, q, last_binding) do
        case schema.field_spec(field) do
          {:error, :unknown_field} ->
            if schema.entity() == field do
              filter(schema, rest, op, value, q, last_binding)
            else
              nil
            end

          {:ok, _, _column} ->
            schema.filter(q, field, op, value, on: last_binding)

          {:ok, :has_many, _, next_schema} ->
            {field, binding} = query_binding(field)
            q = schema.join(q, field, parent: last_binding, child: binding)
            filter(next_schema, rest, op, value, q, binding)

          {:ok, :belongs_to, _, next_schema, _} ->
            {field, binding} = query_binding(field)
            q = schema.join(q, field, parent: binding, child: last_binding)
            filter(next_schema, rest, op, value, q, binding)
        end
      end

      defp query_binding({_, _} = field), do: field
      defp query_binding(field) when is_atom(field), do: {field, field}

      defp combine(q, q, _), do: q
      defp combine(q, nil, _), do: q
      defp combine(nil, prev, _), do: prev
      defp combine(q, prev, :union), do: Ecto.Query.union(prev, ^q)
      defp combine(q, prev, :intersect), do: Ecto.Query.intersect(prev, ^q)
    end
  end

  def evaluate_fun(repo) do
    quote do
      def evaluate(nil, _), do: nil
      def evaluate(value, []), do: value

      def evaluate(_, %{app: app, env: env, key: key}) do
        app |> Application.fetch_env!(env) |> Keyword.fetch!(key)
      end

      def evaluate(_, {:literal, v}), do: v

      def evaluate(%{__struct__: _} = context, [:"**"]), do: context

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

      def evaluate(%{__struct__: schema} = context, [:"**", ancestor | rest]) do
        case schema.shortest_path_to(ancestor) do
          [] ->
            if schema.entity() == ancestor do
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
              rel = context |> unquote(repo).preload(field) |> Map.get(field)
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
  end

  def compare_fun do
    quote do
      def compare(nil, nil, _), do: true
      def compare(nil, _, _), do: false
      def compare(v, v, :eq), do: true
      def compare(%{id: id}, %{id: id}, :eq), do: true
      def compare(%{id: id}, id, :eq), do: true
      def compare(id, %{id: id}, :eq), do: true
      def compare([], _, :eq), do: true
      def compare(v1, v2, :eq) when is_list(v1), do: Enum.any?(v1, &compare(&1, v2, :eq))
      def compare(_, _, :eq), do: false

      def compare(v1, v2, :gt), do: v1 > v2
      def compare(v1, v2, :gte), do: v1 >= v2
      def compare(v1, v2, :lt), do: v1 < v2
      def compare(v1, v2, :lte), do: v1 <= v2

      def compare(v, values, :in) when is_list(v) and is_list(values) do
        v = comparable(v)
        values = comparable(values)

        not Enum.empty?(v -- v -- values)
      end

      def compare(v, values, :in) when is_list(values) do
        v = comparable(v)
        values = comparable(values)

        Enum.member?(values, v)
      end

      def compare(v, value, :in), do: compare(v, [value], :in)

      def compare(v, values, :not_in) when is_list(v) and is_list(values) do
        v = comparable(v)
        values = comparable(values)

        Enum.empty?(v -- v -- values)
      end

      def compare(v, values, :not_in) when is_list(values) do
        v = comparable(v)
        values = comparable(values)

        !Enum.member?(values, v)
      end

      def compare(v, value, :not_in), do: compare(v, [value], :not_in)

      defp comparable(values) when is_list(values), do: Enum.map(values, &comparable/1)
      defp comparable(%{id: id}), do: %{id: id}
      defp comparable(other), do: other
    end
  end
end
