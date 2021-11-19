defmodule Analytic.ClientIdTest do
  use Graphism.Case

  describe "client ids" do
    defmodule Schema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :foo, modifiers: [:client_ids] do
        string(:name)
        action(:list)
        action(:create)
      end

      entity :bar do
        string(:name)
        action(:list)
        action(:create)
      end
    end

    test "can be enabled per entity" do
      assert :foo |> mutation(:create) |> arg?(:id)
      refute :bar |> mutation(:create) |> arg?(:id)
    end
  end
end
