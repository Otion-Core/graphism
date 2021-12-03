defmodule DateTest do
  use ExUnit.Case

  describe "date attributes" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :user do
        date(:dob)
        action(:list)
        action(:create)
      end
    end

    test "are supported" do
      user = Absinthe.Schema.lookup_type(__MODULE__.Schema, :user)
      dob = user.fields.dob
      assert %Absinthe.Type.NonNull{of_type: :date} == dob.type
    end
  end
end
