defmodule Graphism.QueryBuilder do
  @moduledoc """
  Generates convenience functions for powerful generation of complex queries.

  For example, given the following schema:

  ```elixir
  entity :user do
    unique(string(:name))
    boolean(:active, default: true)
    has_many(:posts)
  end

  entity :post do
    unique(string(:slug))
    boolean(:active, default: true)
    belongs_to(:user)
    has_many(:comments)
  end

  entity :comment do
    string(:text)
    boolean(:active, default: true)
    belongs_to(:post)
  end
  ```

  the following abstract query:


  ```elixir
  q = Blog.Schema.filter({:all, [
    {Blog.Schema.Comment, [:post, :slug], :eq, "P123"},
    {Blog.Schema.Comment, [:"**", :user], :eq, Ecto.UUID.generate()},
    {Blog.Schema.Comment, [[:post], [:"**", :user]], :eq, Ecto.UUID.generate()},
    {:first, [
      {Blog.Schema.Comment, [:post, :slug], :eq, "P098"},
      {Blog.Schema.Comment, [:comment, :post, :slug], :eq, "P091"},
      {Blog.Schema.Comment, [:"**", :user], :eq, Ecto.UUID.generate()}
    ]}
  ]})
  ```

  translates into:


  ```elixir
  #Ecto.Query<from c0 in Blog.Schema.Comment, as: :comment,
  join: p1 in Blog.Schema.Post, as: :post, on: p1.id == c0.post_id,
  where: p1.slug == ^"P123",
  intersect: (from c0 in Blog.Schema.Comment,
  as: :comment,
  join: p1 in Blog.Schema.Post,
  as: :post,
  on: p1.id == c0.post_id,
  where: p1.user_id == ^"5ed1fb19-4f1b-4926-abe0-0a28fb42dadd"),
  intersect: (from c0 in Blog.Schema.Comment,
  as: :comment,
  where: c0.post_id == ^"5064fe2a-e392-4a2a-92d5-86c85befced7",
  union: (from c0 in Blog.Schema.Comment,
  as: :comment,
  join: p1 in Blog.Schema.Post,
  as: :post,
  on: p1.id == c0.post_id,
  where: p1.user_id == ^"5064fe2a-e392-4a2a-92d5-86c85befced7")),
  intersect: (from c0 in Blog.Schema.Comment,
  as: :comment,
  join: p1 in Blog.Schema.Post,
  as: :post,
  on: p1.id == c0.post_id,
  where: p1.slug == ^"P098",
  union: (from c0 in Blog.Schema.Comment,
  as: :comment,
  join: p1 in Blog.Schema.Post,
  as: :post,
  on: p1.id == c0.post_id,
  where: p1.slug == ^"P091"),
  union: (from c0 in Blog.Schema.Comment,
  as: :comment,
  join: p1 in Blog.Schema.Post,
  as: :post,
  on: p1.id == c0.post_id,
  where: p1.user_id == ^"f6dc2148-7012-4fde-820e-a2dd4699d122"))>
  ```

  To prove that bindings are correctly set, we can actually execute the query:

  ```elixir
  iex> Blog.Repo.all(q)

  21:25:54.136 [debug] QUERY OK source="comments" db=2.0ms decode=1.4ms queue=2.2ms idle=274.4ms
  SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."slug" = $1) INTERSECT (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."user_id" = $2)) INTERSECT (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 WHERE (c0."post_id" = $3) UNION (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."user_id" = $4))) INTERSECT (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."slug" = $5) UNION (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."slug" = $6)) UNION (SELECT c0."id", c0."text", c0."active", c0."post_id", c0."inserted_at", c0."updated_at" FROM "comments" AS c0 INNER JOIN "posts" AS p1 ON p1."id" = c0."post_id" WHERE (p1."user_id" = $7))) ["P123", "c03a7c37-5193-4555-a1a1-e8bac37ce825", "7928ce87-1f4c-4a42-aa31-29a66ba21dfb", "7928ce87-1f4c-4a42-aa31-29a66ba21dfb", "P098", "P091", "b48f5fb2-9c49-427f-a2ad-86d9c63c044a"]
  []
  ```

  """

  def funs() do
    quote do
      import Ecto.Query

      def filter({:all, filters}) when is_list(filters) do
        filters
        |> Enum.reduce(nil, fn f, q ->
          f
          |> filter()
          |> combine(q, :intersect)
        end)
      end

      def filter({:first, filters}) when is_list(filters) do
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

      def filter(schema, [field | rest] = path, op, value, q, last_binding) do
        if schema.field_spec(field) == {:error, :unknown_field} do
          if schema.entity() == field do
            if rest == [] do
              do_filter(schema, [:id], op, value, q, last_binding)
            else
              filter(schema, rest, op, value, q, last_binding)
            end
          else
            nil
          end
        else
          do_filter(schema, path, op, value, q, last_binding)
        end
      end

      defp do_filter(schema, [field | rest], op, value, q, last_binding) do
        {field, binding} =
          case field do
            {field, binding} -> {field, binding}
            field -> {field, field}
          end

        case schema.field_spec(field) do
          {:error, :unknown_field} ->
            nil

          {:ok, _, _column} ->
            schema.filter(q, field, op, value, on: last_binding)

          {:ok, :has_many, _, next_schema} ->
            q = schema.join(q, field, parent: last_binding, child: binding)
            filter(next_schema, rest, op, value, q, binding)

          {:ok, :belongs_to, _, _next_schema, _} when rest == [] ->
            schema.filter(q, field, op, value, parent: last_binding)

          {:ok, :belongs_to, _, next_schema, _} ->
            q = schema.join(q, field, parent: binding, child: last_binding)
            filter(next_schema, rest, op, value, q, binding)
        end
      end

      defp combine(q, q, _), do: q
      defp combine(q, nil, _), do: q
      defp combine(nil, prev, _), do: prev
      defp combine(q, prev, :union), do: Ecto.Query.union(prev, ^q)
      defp combine(q, prev, :intersect), do: Ecto.Query.intersect(prev, ^q)
    end
  end
end
