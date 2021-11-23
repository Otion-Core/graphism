defmodule Analytic.KeyTest do
  use Graphism.Case

  describe "keys" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :user do
        unique(string(:name))
        action(:list)
      end

      entity :organisation do
        unique(string(:country))
        unique(string(:name))
        key([:country, :name])
        action(:read)
      end

      entity :membership do
        belongs_to(:user)
        belongs_to(:organisation)
        key([:user, :organisation])
        action(:read)
        action(:create)
      end
    end

    test "can be defined on relations" do
      query = query!(:membership, :by_user_and_organisation)

      assert arg?(query, :user)
      assert arg?(query, :organisation)
    end

    test "can be defined on attributes" do
      query = query!(:organisation, :by_country_and_name)

      assert arg?(query, :country)
      assert arg?(query, :name)
    end
  end
end
