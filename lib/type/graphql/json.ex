defmodule Graphism.Type.Graphql.Json do
  @moduledoc false

  use Absinthe.Schema.Notation

  scalar :json, name: "Json" do
    description("""
    The `Json` scalar type represents arbitrary json string data, represented as UTF-8
    character sequences. The Json type is most often used to represent a free-form
    human-readable json string.
    """)

    serialize(&encode_json/1)
    parse(&decode_json/1)
  end

  defp decode_json(%{value: value}) do
    case Jason.decode(value) do
      {:ok, result} -> {:ok, result}
      _ -> :error
    end
  end

  defp decode_json(%Absinthe.Blueprint.Input.Null{}), do: {:ok, nil}

  defp decode_json(_other), do: :error

  defp encode_json(value), do: value
end
