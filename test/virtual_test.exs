defmodule VirtualTest do
  use ExUnit.Case

  describe "virtual entities" do
    defmodule AllowEverything do
      def allow?(_, _), do: true
      def scope(q, _), do: q
    end

    defmodule Describe do
      def execute(_args) do
        [%{name: "My Blog"}]
      end
    end

    defmodule MyRepo do
      use Ecto.Repo,
        otp_app: :graphism,
        adapter: Ecto.Adapters.Postgres
    end

    defmodule MySchema do
      use Graphism, repo: MyRepo

      allow(VirtualTest.AllowEverything)

      entity :blog, modifiers: [:virtual] do
        string(:name)
        action(:list, using: VirtualTest.Describe)
      end

      entity :post do
        string(:title)
        action(:create)
      end
    end

    test "can be queried" do
      parent = %{}
      args = %{}
      resolution = %{context: %{}}
      {:ok, [blog]} = VirtualTest.MySchema.Blog.Resolver.list(parent, args, resolution)
      assert "My Blog" == blog.name
    end
  end
end
