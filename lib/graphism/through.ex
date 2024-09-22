defmodule Graphism.Through do
  @moduledoc """
  Adds support for :through associations

  When dealing with :through associations, we hit a discrepancy between the theorical inverse
  relation and the effective inverse relation. The theorical inverse relation is from the target
  entity to the source entry, however the effective inverse relation is from the target to an
  intermediary source.

  For example, if we have :blogs, :posts, and :tags, a :post can have many :tags. If we define a
  direct :has_many relation between :blogs and :tags, then the theorical inverse relation is from
  :tag to :blog, and is of type :belongs_to.

  However, if the relation is not direct, but rather goes :through [:posts, :tags), then the
  effective inverse relation is from :tag to :post.

  This impacts the way the dataloader is configured in order to resolve fields.
  """

  alias Graphism.Entity

  import Graphism.Evaluate

  @doc """
  Returns the effective inverse relation

  The returned relation can be of type :belongs_to but also :has_many.
  """
  def inverse_relation!(schema, e, through) do
    effective_rel =
      Enum.reduce(through, nil, fn
        field, nil ->
          Entity.relation!(e, field)

        field, rel ->
          schema
          |> Entity.find_entity!(rel[:target])
          |> Entity.relation!(field)
      end)

    unless effective_rel do
      raise "Could not resolve through relation #{inspect(through)} of #{e[:name]}"
    end

    source = Entity.find_entity!(schema, effective_rel[:source])
    Entity.inverse_relation(schema, source, effective_rel[:name])
  end

  @doc """
  The ids the dataloader needs to filter by, when the effective inverse relation is of type `:belongs_to`.
  This applies to the example above between :post and :tag. Here the ids are :post ids. The query
  will be on :tags and the filter will be on column :post_id.
  """
  def parent_ids(model, through) do
    # We drop the last item from the path, because we are evaluating ids of parents
    path = Enum.drop(through, -1)

    model
    |> evaluate(path)
    |> ids()
  end

  @doc """
  The ids the the dataloader needs to filter by, when the effective inverse relation is of type
  `:has_many`. This applies to more complex scenarios where we are going through relations of type
  :belong_to. In this case, the filter is on column :id, of the target resource, and so are the ids
  returned.
  """
  def children_ids(model, through) do
    model
    |> evaluate(through)
    |> ids()
    |> Enum.uniq()
  end

  defp ids(%{id: id}), do: [id]

  defp ids(items) when is_list(items) do
    items
    |> Enum.map(&ids/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp ids(_), do: nil
end
