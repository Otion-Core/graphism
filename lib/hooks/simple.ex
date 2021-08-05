defmodule Graphism.Hooks.Simple do
  @moduledoc """
  A Graphism behaviour for executing a simple hook.

  Takes a map of data, and transforms it into a new map of data.
  """
  @type data :: map()
  @type result :: {:ok, data()} | {:error, term()}

  @callback execute(data()) :: result()
end
