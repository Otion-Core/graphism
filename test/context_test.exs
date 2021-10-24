defmodule ContextTest do
  use ExUnit.Case

  import Graphism.Context

  test "flattens a deeply nested context" do
    # assert %{post: %{id: 1}, blog: %{id: 2}, owner: %{id: 3}, org: %{id: 4}, site: %{id: 6}} ==
    #          from(%{}, %{
    #            post: %{id: 1, owner: %{id: 3, org: %{id: 4}}, blog: %{id: 2, site: %{id: 6}}}
    #          })
  end
end
