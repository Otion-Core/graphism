defmodule Graphism.Auth do
  @moduledoc "Authorization module definition"

  def auth_funs do
    quote do
      def allow?(_args, _context), do: true
      def scope(q, _context), do: q
    end
  end
end
