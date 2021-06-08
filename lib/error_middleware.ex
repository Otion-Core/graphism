defmodule Graphism.ErrorMiddleware do
  @behaviour Absinthe.Middleware
  def call(resolution, _) do
    errors = Enum.flat_map(resolution.errors, &handle_error/1)
    %{resolution | errors: errors}
  end

  defp handle_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {err, _opts} -> err end)
    |> Enum.map(fn {k, v} ->
      k = Inflex.camelize(k, :lower)
      v = message(v)
      [message: v, field: k]
    end)
  end

  defp handle_error(error), do: [error]

  defp message([msg]) when is_binary(msg), do: msg
  defp message(msg), do: msg
end
