defmodule Graphism.Policy do
  @moduledoc false

  def scope_from(do: {op, _, [prop, value]}) do
    %{op: op_for(op), prop: prop, value: value}
  end

  def with_name(scope, name), do: Map.put(scope, :name, name)
  defp op_for(:==), do: :eq
end
