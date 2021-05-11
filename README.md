# Graphism

An Elixir DSL that makes it easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.


## Installation

This library can be installed by adding `graphism` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:graphism,
        git: "https://github.com/gravity-core/graphism.git", branch: "main"}
  ]
end
```

## Your first schema

Define a new schema module 

```elixir
defmodule MyBlogWeb.Schema do
  use Graphism,
    repo: MyBlog.Repo

    
  entity :post do
    attribute :id, :id
    attribute :title, :string
    attribute :body, :string
    has_many :comments
  end

  entity :comment do
    attribute :id, :id
    attribute :body, :string
    belongs_to :post
  end
end

```

## Generate migrations

Graphism will keep track of your schema changes and 
generate proper Ecto migrations:


```
$ mix graphism.gen.migrations

```
