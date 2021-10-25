defmodule ContextTest do
  use ExUnit.Case

  import Graphism.Context

  defmodule Post do
    defstruct id: "", title: "", blog: nil, user: nil
  end

  defmodule Blog do
    defstruct id: "", name: "", user: nil, org: nil
  end

  defmodule User do
    defstruct id: "", email: "", org: nil
  end

  defmodule Org do
    defstruct id: "", name: ""
  end

  test "flattens a deeply nested context" do
    org = %Org{id: "4", name: "My org"}
    user = %User{id: "3", email: "john@doe.com", org: org}
    blog = %Blog{id: "2", name: "My Blog", user: user, org: org}
    post = %Post{id: "1", title: "Hello", blog: blog, user: user}

    context =
      from(%{}, %{
        post: post
      })

    for key <- [:post, :blog, :user, :org] do
      assert Map.has_key?(context, key)
    end
  end

  test "does not overwrite existing context" do
    org = %Org{id: "4", name: "My org"}
    existing_user = %User{id: "5", email: "jane@doe.com", org: org}
    user = %User{id: "3", email: "john@doe.com", org: org}
    blog = %Blog{id: "2", name: "My Blog", user: user, org: org}
    post = %Post{id: "1", title: "Hello", blog: blog, user: user}

    context =
      from(
        %{
          user: existing_user
        },
        %{
          post: post
        }
      )

    assert existing_user.id == context.user.id
  end
end
