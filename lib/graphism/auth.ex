defmodule Graphism.Auth do
  @moduledoc "Authorization module definition"

  alias Graphism.Hooks

  def module(hooks) do
    Hooks.find(hooks, :allow, :default)
  end
end
