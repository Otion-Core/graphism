defmodule Graphism.Hooks.Authorize do
  @moduledoc """
  A Graphism behaviour for authorizing actions.
  """
  @type data :: map()
  @type context :: map()
  @type query :: Ecto.Query.t()

  @callback allow?(data(), context()) :: boolean()
  @callback scope(query(), context()) :: query()
end
