defmodule Graphism.Role do
  @moduledoc "Definitions for authorization roles"

  def from_block({:has, _, [prop, value]}, _opts) do
    %{prop: prop, value: value}
  end

  def with_name(role, name), do: Map.put(role, :name, name)
end
