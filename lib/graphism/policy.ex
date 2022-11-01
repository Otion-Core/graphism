defmodule Graphism.Policy do
  @moduledoc "Definition of authorization policies"

  def from_block({:allow_always, _, _}, _opts), do: %{action: :allow}
  def from_block({:deny_always, _, _}, _opts), do: %{action: :deny}
  def from_block({:always_allow, _, _}, _opts), do: %{action: :allow}
  def from_block({:always_deny, _, _}, _opts), do: %{action: :deny}

  def from_block({action, _, [{op, _, [prop, value]}]}, _opts) do
    %{action: action_for(action), op: op_for(op), prop: prop, value: value}
  end

  def with_name(policy, name), do: Map.put(policy, :name, name)

  defp action_for(:allow_if), do: :allow
  defp action_for(:deny_if), do: :deny
  defp action_for(:allow), do: :allow
  defp action_for(:deny), do: :deny

  defp op_for(:==), do: :eq
end
