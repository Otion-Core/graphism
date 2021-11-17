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

  describe "arguments from boolean fields with default values" do
    defmodule BooleanInputSchema do
      use Graphism, repo: TestRepo

      allow(AllowEverything)

      entity :todo do
        boolean(:done, default: false)
        has_many(:items, inline: [:create])
        action(:list)
        action(:create)
      end

      entity :item do
        boolean(:done, default: false)
        belongs_to(:todo)
        action(:create)
      end
    end

    test "are optional in input types" do
      item_input = Absinthe.Schema.lookup_type(__MODULE__.BooleanInputSchema, :item_input)
      done = item_input.fields.done
      assert :boolean == done.type
    end

    test "are optional in create mutations" do
      mutations = Absinthe.Schema.lookup_type(__MODULE__.BooleanInputSchema, :todo_mutations)
      done = mutations.fields.create.args.done
      assert :boolean == done.type
    end
  end
end
