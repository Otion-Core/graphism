defmodule Graphism.Hooks.Allow.Always do
  @moduledoc """
  A convenience allow hook that always allows an action.

  This is the default if no :allow has been defined.
  """
  @behaviour Graphism.Hooks.Allow

  @impl Graphism.Hooks.Allow
  def allow?(_, _), do: true
end
