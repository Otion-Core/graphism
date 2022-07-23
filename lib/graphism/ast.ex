defmodule Graphism.Ast do
  @moduledoc "Various code generation helpers"

  def print(ast, condition \\ true) do
    if condition do
      ast
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.puts()
    end

    ast
  end

  def var(name) when is_atom(name), do: Macro.var(name, nil)
  def var(other), do: other |> Keyword.fetch!(:name) |> var()

  def vars(names), do: Enum.map(names, &var(&1))
end
