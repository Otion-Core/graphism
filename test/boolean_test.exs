defmodule BooleanTest do
  use ExUnit.Case

  describe "boolean attributes" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :calendar do
        boolean(:active, default: true)
        action(:list)
        action(:create)
      end
    end

    test "are non null fields if they have a default value" do
      calendar = Absinthe.Schema.lookup_type(__MODULE__.Schema, :calendar)
      active = calendar.fields.active
      assert %Absinthe.Type.NonNull{of_type: :boolean} == active.type
    end
  end
end
