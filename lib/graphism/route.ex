defmodule Graphism.Route do
  @moduledoc "Conventions around http routes"

  def for_item(e), do: e |> for_collection() |> with_param("id") |> route()
  def for_collection(e), do: route("/#{e[:plural]}")
  def for_aggregation(e), do: e |> for_collection() |> aggregated() |> route()
  def for_children(e, rel), do: e |> for_item() |> suffixed_with(rel[:name]) |> route()
  def for_children_aggregation(e, rel), do: e |> for_children(rel) |> aggregated() |> route()

  def for_action(e, action, params \\ []) do
    base = e |> for_collection() |> suffixed_with(action)

    Enum.reduce(params, base, fn param, path ->
      path
      |> suffixed_with(param)
      |> with_param(param)
    end)
    |> route()
  end

  def for_action_aggregation(e, action, params \\ []) do
    e
    |> for_action(action, params)
    |> aggregated()
  end

  def for_key(e, key) do
    key[:fields]
    |> Enum.reduce(for_aggregation(e), fn field, path ->
      path
      |> suffixed_with(field)
      |> with_param(field)
    end)
    |> route()
  end

  def for_key_aggregation(e, key) do
    e
    |> for_key(key)
    |> aggregated()
  end

  defp suffixed_with(path, suffix), do: "#{path}/#{suffix}"
  defp with_param(path, param), do: suffixed_with(path, ":#{param}")
  defp aggregated(path), do: suffixed_with(path, "aggregation")

  defp route(path) do
    path
    |> String.split("/")
    |> Enum.map(&Inflex.camelize/1)
    |> Enum.join("/")
    |> String.downcase()
  end
end
