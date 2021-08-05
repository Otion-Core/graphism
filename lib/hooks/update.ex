defmodule Graphism.Hooks.Update do
  @moduledoc """
  A Graphism behaviour for executing an update hook.

  An update hook is a special hook that takes the entity being updated, and the new attributes
  being set.
  """
  @type entity :: map()
  @type data :: map()
  @type result :: {:ok, data()} | {:error, term()}

  @callback execute(entity(), data()) :: result()
end
