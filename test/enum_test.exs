defmodule EnumTest do
  use ExUnit.Case

  describe "enumeration attributes" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      data(:categories, [:work, :personal])

      entity :calendar do
        string(:category, one_of: :categories, default: :personal)
        action(:list)
        action(:create)
      end
    end

    test "are non null fields" do
      calendar = Absinthe.Schema.lookup_type(__MODULE__.Schema, :calendar)
      category = calendar.fields.category
      assert %Absinthe.Type.NonNull{of_type: :categories} == category.type
    end
  end
end
