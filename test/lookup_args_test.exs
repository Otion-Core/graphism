defmodule Analytic.LookupArgsTest do
  use ExUnit.Case

  describe "lookup args" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :user do
        unique(string(:email))
        action(:list)
      end

      entity :invite do
        belongs_to(:user)
        action(:create, args: [user: :email])
      end
    end

    test "replace original mutation args" do
      mutations = Absinthe.Schema.lookup_type(__MODULE__.Schema, :invite_mutations)
      refute mutations.fields.create.args[:user]
      user_email = mutations.fields.create.args.user_email
      assert %Absinthe.Type.NonNull{of_type: :string} == user_email.type
    end
  end
end
