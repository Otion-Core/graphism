defmodule Graphism.Hooks do
  @moduledoc "Provides with hooks information about a schema"

  def find(hooks, kind, name) do
    with hook when hook != nil <- Enum.find(hooks, &(&1.kind == kind and &1.name == name)) do
      hook.module
    end
  end
end
