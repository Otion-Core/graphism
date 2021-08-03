defmodule Graphism.Allow.Always do
  @moduledoc """
  A convenience allow hook that always allows an action.

  This is the default :allow policy that will be set on an action, if no :allow has been defined
  """

  def allow?(_, _), do: true
end
