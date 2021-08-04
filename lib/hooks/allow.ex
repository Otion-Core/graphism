defmodule Graphism.Hooks.Allow do
  @moduledoc """
  A Graphism behaviour for authorizing actions.

  Given a set of data, and a context, both maps, implementations should return whether or not the action
  is permitted.
  """
  @type data :: map()
  @type context :: map()

  @callback allow?(data(), context()) :: boolean()
end
